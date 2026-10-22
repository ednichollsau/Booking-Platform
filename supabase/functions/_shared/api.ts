export const env = (name: string) => Deno.env.get(name) || ''
export async function db(path: string, method = 'GET', body?: unknown) {
  const key = env('SUPABASE_SERVICE_ROLE_KEY')
  const response = await fetch(`${env('SUPABASE_URL')}/rest/v1/${path}`, {
    method, headers: {apikey:key, Authorization:`Bearer ${key}`, 'Content-Type':'application/json', Prefer:'return=representation'},
    body:body === undefined ? undefined : JSON.stringify(body)
  })
  if (!response.ok) throw new Error(`Database request failed (${response.status})`)
  return response.status===204 ? null : response.json()
}
export const rpc = (name:string, args:unknown) => db(`rpc/${name}`,'POST',args)
export async function stripe(path:string, fields:Record<string,string>, idempotencyKey?:string) {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    method:'POST',headers:{Authorization:`Bearer ${env('STRIPE_SECRET_KEY')}`,'Content-Type':'application/x-www-form-urlencoded',...(idempotencyKey?{'Idempotency-Key':idempotencyKey}:{})},
    body:new URLSearchParams(fields)
  })
  if(!response.ok) throw new Error(`Payment provider request failed (${response.status})`)
  return response.json()
}
export const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'}
export const json = (body:unknown,status=200) => new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}})

export async function stripeGet(path:string) {
 const response=await fetch(`https://api.stripe.com/v1/${path}`,{headers:{Authorization:`Bearer ${env('STRIPE_SECRET_KEY')}`}})
 if(!response.ok) throw new Error(`Payment provider request failed (${response.status})`)
 return response.json()
}
