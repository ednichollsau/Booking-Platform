import {readFile} from 'node:fs/promises'
import {privateDecrypt,createDecipheriv,constants} from 'node:crypto'
import {PGlite} from '@electric-sql/pglite'
const [file,keyFile]=process.argv.slice(2)
const envelope=JSON.parse(await readFile(file,'utf8'))
const key=privateDecrypt({key:await readFile(keyFile),padding:constants.RSA_PKCS1_OAEP_PADDING,oaepHash:'sha256'},Buffer.from(envelope.key,'base64'))
const decipher=createDecipheriv('aes-256-gcm',key,Buffer.from(envelope.iv,'base64'));decipher.setAuthTag(Buffer.from(envelope.tag,'base64'))
const plaintext=Buffer.concat([decipher.update(Buffer.from(envelope.data,'base64')),decipher.final()])
let backup
try {backup=JSON.parse(plaintext.toString())} catch {throw new Error('Backup validation failed')}
plaintext.fill(0);key.fill(0)
const db=new PGlite()
try {
 await db.exec(await readFile(new URL('../tests/baseline.sql',import.meta.url),'utf8'))
 if(backup.data.pending_checkouts) {
  for(const name of ['booking-integrity','payments','notifications','account-privacy']) await db.exec(await readFile(new URL(`../database/${name}.sql`,import.meta.url),'utf8'))
 }
 if(backup.data.booking_time_changes) for(const name of ['admin-tools','subscribers']) await db.exec(await readFile(new URL(`../database/${name}.sql`,import.meta.url),'utf8'))
 await db.exec('set session_replication_role=replica')
 for(const user of backup.auth_mapping) await db.query('insert into auth.users(id,email,email_confirmed_at) values($1,$2,$3)',[user.id,user.email,user.email_confirmed_at])
 const order=['services','packages','customers','package_contents','customer_packages','customer_package_balances','bookings','availability_rules','availability_overrides','audit_log','pending_checkouts','notification_jobs','account_deletion_requests','booking_time_changes','mailing_subscribers']
 const counts={}
 for(const table of order) {
  const rows=backup.data[table];if(!rows) continue
  for(const row of rows) {
   const names=Object.keys(row)
   const values=names.map(n=>row[n]!==null && typeof row[n]==='object'?JSON.stringify(row[n]):row[n])
   await db.query(`insert into public.${table}(${names.map(n=>'"'+n+'"').join(',')}) values(${names.map((_,i)=>'$'+(i+1)).join(',')})`,values)
  }
  counts[table]=(await db.query(`select count(*)::int as n from public.${table}`)).rows[0].n
  if(counts[table]!==rows.length) throw new Error('Restored row count mismatch')
 }
 console.log(JSON.stringify({verified:true,tables:counts,authentication:'Mapping only; credentials are not exported.'}))
} catch { console.error('Encrypted backup restore verification failed; no patient data was printed.'); process.exitCode=1 } finally {await db.close()}
