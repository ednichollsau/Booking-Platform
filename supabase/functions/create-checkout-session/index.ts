import {db,rpc,stripe,env,cors,json} from '../_shared/api.ts'
export async function handler(req:Request) {
  if(req.method==='OPTIONS') return new Response('ok',{headers:cors})
  if(req.method!=='POST') return json({error:'Method not allowed'},405)
  try {
    const input = await req.json()
    const returnUrl = new URL(input.returnUrl || 'https://book.ednicholls.com/')
    if(returnUrl.origin!=='https://book.ednicholls.com') return json({error:'Invalid return address'},400)
    returnUrl.search=''; returnUrl.hash=''
    let payload, kind, item
    if(input.booking) {
      payload=input.booking;kind='booking'
      if(!/^[0-9a-f-]{36}$/i.test(payload.service_id || '') || !payload.email || JSON.stringify(payload).length>50000) return json({error:'Invalid booking details'},400)
      item=(await db(`services?id=eq.${payload.service_id}&active=eq.true`))[0]
    } else if(input.packageId) {
      if(!/^[0-9a-f-]{36}$/i.test(input.packageId)) return json({error:'Invalid package'},400)
      const auth=await fetch(`${env('SUPABASE_URL')}/auth/v1/user`,{headers:{apikey:env('SUPABASE_ANON_KEY'),Authorization:req.headers.get('Authorization') || ''}})
      if(!auth.ok) return json({error:'Please sign in'},401)
      const user=await auth.json()
      if(!user.email_confirmed_at) return json({error:'Please verify your email'},403)
      const customer=(await db(`customers?auth_user_id=eq.${user.id}&select=id,email`))[0]
      if(!customer) return json({error:'Customer record missing'},400)
      payload={customer_id:customer.id,package_id:input.packageId,email:customer.email};kind='package'
      item=(await db(`packages?id=eq.${input.packageId}&active=eq.true`))[0]
    } else return json({error:'Missing booking or package'},400)
    if(!item) return json({error:'Item unavailable'},400)
    const pending=await rpc('stage_checkout',{p_kind:kind,p_payload:payload})
    const session=await stripe('checkout/sessions',{
      mode:'payment','payment_method_types[0]':'card','line_items[0][price_data][currency]':'gbp',
      'line_items[0][price_data][product_data][name]':item.name,'line_items[0][price_data][unit_amount]':String(pending.amount),
      'line_items[0][quantity]':'1',customer_email:payload.email,
      success_url:`${returnUrl}?stripe_success=1&type=${kind}&checkout_id=${pending.id}&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url:`${returnUrl}?stripe_cancel=1`, 'metadata[type]':kind,'metadata[pending_id]':pending.id,
      expires_at:String(Math.floor(Date.now()/1000)+1800)
    },`checkout-${pending.id}`)
    await db(`pending_checkouts?id=eq.${pending.id}`,'PATCH',{stripe_session_id:session.id})
    return json({url:session.url})
  } catch { return json({error:'We could not start payment. Please refresh availability and try again.'},400) }
}
Deno.serve(handler)
