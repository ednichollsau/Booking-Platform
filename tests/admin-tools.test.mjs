import test from 'node:test'
import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {PGlite} from '@electric-sql/pglite'
test('admin credits, rescheduling and subscriber safeguards',async t=>{
 const db=new PGlite();try{
 await db.exec(await readFile(new URL('./baseline.sql',import.meta.url),'utf8'))
 for(const name of ['booking-integrity','payments','notifications','account-privacy','admin-tools','subscribers']) await db.exec(await readFile(new URL(`../database/${name}.sql`,import.meta.url),'utf8'))
 const id=async sql=>(await db.query(sql)).rows[0].id
 const admin=await id("insert into auth.users values(gen_random_uuid(),'acu@ednicholls.com',now()) returning id")
 const user=await id("insert into auth.users values(gen_random_uuid(),'patient@example.test',now()) returning id")
 const customer=await id(`insert into customers(auth_user_id,email,first_name) values('${user}','patient@example.test','Test') returning id`)
 const service=await id("insert into services(slug,name,duration_minutes,price_pence,slot_interval_minutes,concurrent_capacity) values('multi-bed','Multi',45,3500,15,3) returning id")
 await db.exec(`insert into packages(slug,name,total_sessions,price_pence) values('standard','Standard',4,12000);insert into availability_rules(day_of_week,start_time,end_time,service_id) values(4,'18:00','21:00','${service}');set request.jwt.claim.sub='${admin}';set role authenticated`)
 const key=(await db.query('select gen_random_uuid() as id')).rows[0].id
 const assign=()=>db.query('select admin_assign_package($1,$2,$3,$4,$5) as id',[customer,'Three sessions',[{service_id:service,quantity:3}],9000,key])
 let cp
 await t.test('custom credits are atomic, 365 days and retry-safe',async()=>{
 cp=(await assign()).rows[0].id;assert.equal((await assign()).rows[0].id,cp)
 const r=(await db.query('select * from customer_packages where id=$1',[cp])).rows[0]
 assert.equal(r.custom_name,'Three sessions');assert.equal(+r.expires_at- +r.purchased_at,365*86400000)
 assert.equal((await db.query('select sessions_remaining from customer_package_balances where customer_package_id=$1',[cp])).rows[0].sessions_remaining,3)
 })
 await db.exec(`set request.jwt.claim.sub='${user}'`)
 await t.test('patient cannot assign credits',async()=>await assert.rejects(assign(),/Not authorized/))
 const day=(await db.query("select to_char(current_date+((4-extract(dow from current_date)::int+7)%7)+14,'YYYY-MM-DD') as day")).rows[0].day
 const instant=time=>`('${day} ${time}'::timestamp at time zone 'Europe/London')`
 const bid=await id(`select redeem_package_session('${cp}','${service}',${instant('18:00')},${instant('18:45')}) as id`)
 await t.test('patient cannot reschedule through admin endpoint',async()=>await assert.rejects(db.query(`select admin_reschedule_booking('${bid}',${instant('18:00')},${instant('18:15')})`),/Not authorized/))
 await db.exec(`set request.jwt.claim.sub='${admin}'`)
 await t.test('rescheduling preserves credits and queues one change message',async()=>{
 await db.query(`select admin_reschedule_booking('${bid}',${instant('18:00')},${instant('18:15')})`)
 assert.equal((await db.query(`select sessions_remaining from customer_package_balances where customer_package_id='${cp}'`)).rows[0].sessions_remaining,2)
 assert.equal((await db.query("select count(*)::int as n from notification_jobs where kind='reschedule'")).rows[0].n,1)
 await assert.rejects(db.query(`select admin_reschedule_booking('${bid}',${instant('18:00')},${instant('18:30')})`),/changed/)
 await assert.rejects(db.query(`select admin_reschedule_booking('${bid}',${instant('18:15')},${instant('16:30')})`),/outside/)
 })
 await t.test('import deduplicates and cannot undo unsubscribe',async()=>{
 const record=()=>db.query("select admin_record_subscriber('List@Example.test','Test','Reading form','Recorded consent wording')")
 await record();await record();const sub=(await db.query("select * from mailing_subscribers where email='list@example.test'")).rows[0]
 await db.query('select unsubscribe_marketing($1)',[sub.unsubscribe_token]);await record()
 assert.equal((await db.query('select subscribed from mailing_subscribers where id=$1',[sub.id])).rows[0].subscribed,false)
 })
 await db.exec(`set request.jwt.claim.sub='${user}'`)
 await t.test('patient preference is explicit and subscriber list stays private',async()=>{
 assert.equal((await db.query('select my_marketing_preference() as subscribed')).rows[0].subscribed,false)
 await db.query('select set_my_marketing_preference(true)')
 assert.equal((await db.query('select my_marketing_preference() as subscribed')).rows[0].subscribed,true)
 assert.equal((await db.query('select * from mailing_subscribers')).rows.length,0)
 await db.query('select set_my_marketing_preference(false)')
 assert.equal((await db.query('select my_marketing_preference() as subscribed')).rows[0].subscribed,false)
 })
 }finally{await db.close()}
})
