import test from 'node:test'
import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {PGlite} from '@electric-sql/pglite'

test('booking rules, permissions, credit expiry and cancellation', async t => {
  const db = new PGlite()
  try {
    await db.exec(await readFile(new URL('./baseline.sql',import.meta.url),'utf8'))
    await db.exec(await readFile(new URL('../database/booking-integrity.sql',import.meta.url),'utf8'))
    await db.exec(await readFile(new URL('../database/payments.sql',import.meta.url),'utf8'))
    await db.exec(await readFile(new URL('../database/notifications.sql',import.meta.url),'utf8'))
    await db.exec(await readFile(new URL('../database/account-privacy.sql',import.meta.url),'utf8'))
    const id = async sql => (await db.query(sql)).rows[0].id
    const uid = await id("insert into auth.users values(gen_random_uuid(),'patient@example.test',now()) returning id")
    const cid = await id(`insert into customers(auth_user_id,email,first_name) values('${uid}','patient@example.test','Original') returning id`)
    const sid = await id("insert into services(slug,name,duration_minutes,price_pence,slot_interval_minutes,concurrent_capacity) values('multi-bed','Multi',45,3000,15,3) returning id")
    await db.exec(`insert into availability_rules(day_of_week,start_time,end_time,service_id) values(4,'18:00','21:00','${sid}')`)
    const day = (await db.query("select to_char(current_date + ((4 - extract(dow from current_date)::int + 7)%7) + 14,'YYYY-MM-DD') as day")).rows[0].day
    const instant = time => `('${day} ${time}'::timestamp at time zone 'Europe/London')`
    const book = (time, end, email='guest@example.test') => `select create_anonymous_booking(p_email=>'${email}',p_first_name=>'Replacement',p_service_id=>'${sid}',p_starts_at=>${instant(time)},p_ends_at=>${instant(end)}) as id`
    await t.test('rejects outside hours, invalid duration and off-grid requests',async () => {
      await assert.rejects(db.query(book('16:30','17:15')),/outside/)
      await assert.rejects(db.query(book('18:00','18:30')),/duration/)
      await assert.rejects(db.query(book('18:01','18:46')),/outside/)
    })
    await t.test('accepts staggered appointments and rejects duplicate starts',async () => {
      await db.query(book('18:00','18:45'))
      await db.query(book('18:15','19:00'))
      await db.query(book('18:30','19:15'))
      await assert.rejects(db.query(book('18:00','18:45')),/no longer/)
      await db.query(book('18:45','19:30'))
    })
    await t.test('anonymous collision leaves existing personal details intact',async () => {
      await db.query(book('19:00','19:45','patient@example.test'))
      assert.equal((await db.query(`select first_name from customers where id='${cid}'`)).rows[0].first_name,'Original')
      assert.equal((await db.query("select lookup_customer_by_email('patient@example.test') as result")).rows[0].result,null)
    })
    await t.test('paid booking fulfilment is atomic, deduplicated and keeps full intake',async () => {
      const payload={email:'paid@example.test',service_id:sid,starts_at:`${day}T20:00:00Z`,ends_at:`${day}T20:45:00Z`,reason:'full intake '.repeat(100)}
      // Derive a clinic-local slot even when this test is run during BST.
      payload.starts_at=(await db.query(`select ${instant('20:00')} as t`)).rows[0].t.toISOString()
      payload.ends_at=(await db.query(`select ${instant('20:45')} as t`)).rows[0].t.toISOString()
      const staged=(await db.query('select stage_checkout($1,$2) as value',['booking',payload])).rows[0].value
      await db.exec(`set request.jwt.claims='{"role":"service_role"}'`)
      const complete=()=>db.query('select complete_checkout($1,$2,$3,$4,$5) as value',[staged.id,'cs_test_paid','pi_test',3000,'gbp'])
      assert.equal((await complete()).rows[0].value.status,'completed')
      assert.equal((await complete()).rows[0].value.status,'completed')
      const bookings=(await db.query("select intake_response from bookings where notes='stripe:cs_test_paid'" )).rows
      await db.exec(`set request.jwt.claims='{}'`)
      assert.equal(bookings.length,1);assert.equal(bookings[0].intake_response.reason,payload.reason)
      assert.equal((await db.query('select payload from pending_checkouts where id=$1',[staged.id])).rows[0].payload.constructor,Object)
      assert.deepEqual((await db.query('select payload from pending_checkouts where id=$1',[staged.id])).rows[0].payload,{})
    })
    const pid = await id("insert into packages(slug,name,total_sessions,price_pence) values('four','Four',4,12000) returning id")
    await db.exec(`insert into package_contents(package_id,service_id,quantity) values('${pid}','${sid}',4)` )
    await t.test('package activation is atomic and idempotent',async () => {
      const args=`'${cid}','${pid}','cs_test_atomic',12000`
      const first=await id(`select activate_package(${args}) as id`)
      assert.equal(await id(`select activate_package(${args}) as id`),first)
      assert.equal((await db.query(`select sessions_remaining from customer_package_balances where customer_package_id='${first}'`)).rows[0].sessions_remaining,4)
    })
    const cp = await id(`insert into customer_packages(customer_id,package_id,expires_at,amount_paid_pence) values('${cid}','${pid}',now()+interval '1 day',12000) returning id`)
    await db.exec(`insert into customer_package_balances(customer_package_id,service_id,sessions_remaining) values('${cp}','${sid}',4); set request.jwt.claim.sub='${uid}'; set role authenticated;`)
    await t.test('patient cannot change credits or create packages',async () => {
      await assert.rejects(db.query(`insert into customer_packages(customer_id,package_id,expires_at,amount_paid_pence) values('${cid}','${pid}',now()+interval '1 day',0)`),/row-level security/)
      const result = await db.query(`update customer_package_balances set sessions_remaining=100 where customer_package_id='${cp}' returning id`)
      assert.equal(result.rows.length,0)
    })
    let bid
    await t.test('booking before expiry may have appointment after expiry',async () => {
      bid = await id(`select redeem_package_session('${cp}','${sid}',${instant('19:15')},${instant('20:00')}) as id`)
      assert.ok(bid)
      assert.equal((await db.query(`select sessions_remaining from customer_package_balances where customer_package_id='${cp}'`)).rows[0].sessions_remaining,3)
    })
    await t.test('cancellation returns credit only once',async () => {
      const token = (await db.query(`select cancellation_token from bookings where id='${bid}'`)).rows[0].cancellation_token
      await db.query(`select cancel_booking_by_token('${token}')`)
      await db.query(`select cancel_booking_by_token('${token}')`)
      assert.equal((await db.query(`select sessions_remaining from customer_package_balances where customer_package_id='${cp}'`)).rows[0].sessions_remaining,4)
    })
    await t.test('expired package cannot make a new booking',async () => {
      await db.exec(`reset role; update customer_packages set expires_at=now()-interval '1 second' where id='${cp}'; set role authenticated;`)
      await assert.rejects(db.query(`select redeem_package_session('${cp}','${sid}',${instant('19:15')},${instant('20:00')})`),/not active/)
    })
    await t.test('closing an account queues auth deletion and preserves the retention deadline',async () => {
      const result=(await db.query('select delete_my_account() as result')).rows[0].result
      assert.equal(result.ok,true)
      await db.exec('reset role')
      const c=(await db.query(`select * from customers where id='${cid}'`)).rows[0]
      assert.equal(c.auth_user_id,null)
      assert.ok(c.clinical_retention_until)
      assert.equal((await db.query(`select count(*)::int as n from account_deletion_requests where user_id='${uid}'`)).rows[0].n,1)
    })
    await t.test('notification jobs claim once and respect their retry lease',async () => {
      const one=(await db.query('select * from claim_notifications()')).rows
      assert.ok(one.length>0)
      const two=(await db.query('select * from claim_notifications()')).rows
      assert.equal(two.length,0)
    })
  } finally { await db.close() }
})
