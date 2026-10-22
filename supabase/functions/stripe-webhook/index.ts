import {db,rpc,stripe,stripeGet,env} from '../_shared/api.ts'
export async function verifySignature(body:string,header:string,secret:string,now=Date.now()) {
  const parts=header.split(',').map(s=>s.trim())
  const ts=parts.find(p=>p.startsWith('t='))?.slice(2)
  if(!ts || !/^\d+$/.test(ts) || Math.abs(now/1000-Number(ts))>300) return false
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['verify'])
  for(const sig of parts.filter(p=>p.startsWith('v1=')).map(p=>p.slice(3))) {
    if(!/^[a-f0-9]{64}$/i.test(sig)) continue
    const bytes=Uint8Array.from(sig.match(/../g)!,p=>parseInt(p,16))
    if(await crypto.subtle.verify('HMAC',key,bytes,new TextEncoder().encode(`${ts}.${body}`))) return true
  }
  return false
}
export async function handler(req:Request) {
  if(req.method!=='POST') return new Response('Method not allowed',{status:405})
  const body=await req.text()
  if(!await verifySignature(body,req.headers.get('stripe-signature') || '',env('STRIPE_WEBHOOK_SECRET'))) return new Response('Invalid signature',{status:400})
  let event
  try {event=JSON.parse(body)} catch {return new Response('Invalid JSON',{status:400})}
  if(!['checkout.session.completed','checkout.session.async_payment_succeeded'].includes(event.type)) return new Response('ignored')
  const s=event.data.object, m=s.metadata || {}
  if(s.payment_status!=='paid') return new Response('awaiting payment')
  try {
    let pendingId=m.pending_id
    if(!pendingId) {
      // Compatibility for checkouts opened before this release; no new clinical metadata is written.
      const existing=await db(`pending_checkouts?stripe_session_id=eq.${encodeURIComponent(s.id)}&select=id`)
      pendingId=existing[0]?.id
      if(!pendingId) {
        const type=m.type || 'package'
        const old=type==='booking' ? await db(`bookings?notes=eq.${encodeURIComponent('stripe:'+s.id)}&select=id`) : await db(`customer_packages?stripe_payment_id=eq.${encodeURIComponent(s.id)}&select=id`)
        if(old.length) return new Response('already completed')
        const payload=type==='booking' ? {email:m.b_email,first_name:m.b_first_name,last_name:m.b_last_name,phone:m.b_phone,date_of_birth:m.b_dob,gender:m.b_gender,
          emergency_contact_name:m.b_ec_name,emergency_contact_phone:m.b_ec_phone,emergency_contact_relationship:m.b_ec_rel,service_id:m.b_service_id,
          starts_at:m.b_starts_at,ends_at:m.b_ends_at,reason:m.b_reason,medications:m.b_meds,conditions:m.b_cond,electro_consent:m.b_electro==='1',general_consent_version:m.b_consent_v}
          : {customer_id:m.customer_id,package_id:m.package_id}
        const rows=await db('pending_checkouts','POST',{kind:type,payload,expected_amount:s.amount_total,stripe_session_id:s.id})
        pendingId=rows[0].id
      }
    }
    const result=await rpc('complete_checkout',{p_id:pendingId,p_session:s.id,p_payment_intent:s.payment_intent,p_amount:s.amount_total,p_currency:s.currency})
    if(result.status==='refund_required') {
      const pending=(await db(`pending_checkouts?id=eq.${pendingId}&select=refund_id`))[0]
      const refund=pending?.refund_id ? await stripeGet(`refunds/${encodeURIComponent(pending.refund_id)}`) : await stripe('refunds',{payment_intent:s.payment_intent,reason:'requested_by_customer'},`unfulfilled-${s.id}`)
      if(!['succeeded','pending'].includes(refund.status)) throw new Error('Refund requires attention')
      await db(`pending_checkouts?id=eq.${pendingId}`,'PATCH',{status:refund.status==='succeeded'?'refunded':'refund_required',refund_id:refund.id})
      if(refund.status!=='succeeded') return new Response('Refund pending',{status:500})
    }
    return new Response('ok')
  } catch {
    // Stripe retries transient failures. The durable pending row also exposes unresolved payments to the admin.
    console.error('Payment fulfilment requires retry',event.id)
    return new Response('Please retry',{status:500})
  }
}
Deno.serve(handler)
