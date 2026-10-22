import test from 'node:test'
import assert from 'node:assert/strict'
const secrets={STRIPE_WEBHOOK_SECRET:'test-signing-secret',SUPABASE_URL:'https://database.test',SUPABASE_SERVICE_ROLE_KEY:'server-only',SUPABASE_ANON_KEY:'public',STRIPE_SECRET_KEY:'test-key'}
globalThis.Deno={env:{get:key=>secrets[key]},serve:()=>{}}
const {verifySignature,handler:webhook}=await import('../supabase/functions/stripe-webhook/index.ts')
const {handler:checkout}=await import('../supabase/functions/create-checkout-session/index.ts')
const {handler:notifications}=await import('../supabase/functions/_shared/notifications.ts')
const sign=async(body,ts)=>{
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secrets.STRIPE_WEBHOOK_SECRET),{name:'HMAC',hash:'SHA-256'},false,['sign'])
 return `t=${ts},v1=${Buffer.from(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(`${ts}.${body}`))).toString('hex')}`
}
test('Stripe signatures reject forged and stale requests',async()=>{
 const body='{"type":"test"}',now=Date.now(),ts=Math.floor(now/1000)
 assert.equal(await verifySignature(body,await sign(body,ts),secrets.STRIPE_WEBHOOK_SECRET,now),true)
 assert.equal(await verifySignature(body+'x',await sign(body,ts),secrets.STRIPE_WEBHOOK_SECRET,now),false)
 assert.equal(await verifySignature(body,await sign(body,ts-301),secrets.STRIPE_WEBHOOK_SECRET,now),false)
})
test('email endpoints reject anonymous callers before accessing data',async()=>{
 const old=globalThis.fetch;globalThis.fetch=()=>{throw new Error('Must not access data')}
 try {assert.equal((await notifications(new Request('https://test',{method:'POST'}))).status,401)} finally {globalThis.fetch=old}
})
test('clinical text stays in Supabase and never enters Stripe metadata',async()=>{
 const old=globalThis.fetch,calls=[]
 globalThis.fetch=async(url,options={})=>{
  calls.push({url:String(url),...options})
  if(String(url).includes('/services?')) return Response.json([{name:'Appointment'}])
  if(String(url).endsWith('/rpc/stage_checkout')) return Response.json({id:'00000000-0000-0000-0000-000000000001',amount:3000})
  if(String(url).includes('api.stripe.com')) return Response.json({id:'cs_test',url:'https://checkout.stripe.com/test'})
  return Response.json([])
 }
 try {
  const reason='private clinical information '.repeat(50)
  const result=await checkout(new Request('https://test',{method:'POST',body:JSON.stringify({booking:{email:'patient@example.test',service_id:'00000000-0000-0000-0000-000000000002',starts_at:'2027-01-07T18:00Z',ends_at:'2027-01-07T18:45Z',reason}})}))
  assert.equal(result.status,200)
  const stored=JSON.parse(calls.find(c=>c.url.endsWith('/rpc/stage_checkout')).body)
  assert.equal(stored.p_payload.reason,reason)
  const stripe=calls.find(c=>c.url.includes('api.stripe.com'))
  assert.equal(String(stripe.body).includes('clinical'),false)
  assert.deepEqual([...stripe.body.keys()].filter(k=>k.startsWith('metadata')),['metadata[type]','metadata[pending_id]'])
 } finally {globalThis.fetch=old}
})
test('transient payment processing errors request a retry rather than reporting a refund',async()=>{
 const old=globalThis.fetch;globalThis.fetch=async()=>new Response('down',{status:503})
 try {
  const body=JSON.stringify({id:'evt_test',type:'checkout.session.completed',data:{object:{id:'cs_test',payment_status:'paid',metadata:{pending_id:'00000000-0000-0000-0000-000000000001'},payment_intent:'pi_test',amount_total:3000,currency:'gbp'}}})
  const response=await webhook(new Request('https://test',{method:'POST',headers:{'stripe-signature':await sign(body,Math.floor(Date.now()/1000))},body}))
  assert.equal(response.status,500)
 } finally {globalThis.fetch=old}
})
test('change email uses old and new London times across clock change',async()=>{
 const old=globalThis.fetch;let email
 secrets.RESEND_API_KEY='test-resend'
 globalThis.fetch=async(url,options={})=>{
 const path=String(url)
 if(path.includes('internal_settings'))return Response.json([{value:'internal'}])
 if(path.includes('account_deletion_requests'))return Response.json([])
 if(path.includes('/rpc/claim_notifications'))return Response.json([{id:'job',kind:'reschedule',reference_id:'change',audience:'patient',attempts:1}])
 if(path.includes('booking_time_changes'))return Response.json([{booking_id:'booking',old_starts_at:'2026-10-22T17:00:00Z',new_starts_at:'2026-10-29T18:00:00Z'}])
 if(path.includes('/bookings?'))return Response.json([{id:'booking',customer_id:'customer',service_id:'service',status:'confirmed',starts_at:'2026-10-29T18:00:00Z',cancellation_token:'cancel'}])
 if(path.includes('/customers?'))return Response.json([{email:'patient@example.test',first_name:'Test'}])
 if(path.includes('/services?'))return Response.json([{name:'Multi',duration_minutes:45,price_pence:3500}])
 if(path==='https://api.resend.com/emails'){email=JSON.parse(options.body);return Response.json({id:'sent'})}
 return Response.json([])
 }
 try{await notifications(new Request('https://test',{method:'POST',headers:{'X-Internal-Token':'internal'}}));assert.match(email.subject,/Appointment time changed/);assert.match(email.html,/22 October 2026 at 18:00/);assert.match(email.html,/29 October 2026 at 18:00/)}finally{globalThis.fetch=old}
})
