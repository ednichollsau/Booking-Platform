import {db,rpc,env} from './api.ts'
const esc=(v:unknown)=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]!))
const date=(s:string)=>new Date(s).toLocaleDateString('en-GB',{timeZone:'Europe/London',weekday:'long',day:'numeric',month:'long',year:'numeric'})
const time=(s:string)=>new Date(s).toLocaleTimeString('en-GB',{timeZone:'Europe/London',hour:'2-digit',minute:'2-digit'})
const money=(n:number)=>`£${(n/100).toFixed(2)}`
const first=async(path:string)=>(await db(path))[0]
const frame=(heading:string,content:string)=>`<!doctype html><html><body style="font-family:Arial,sans-serif;color:#2a2722;background:#faf8f4;padding:24px"><main style="max-width:560px;margin:auto"><h1 style="font-family:Georgia,serif">${esc(heading)}</h1>${content}<p>Ed Nicholls Acupuncture</p><p><a href="mailto:acu@ednicholls.com">acu@ednicholls.com</a></p></main></body></html>`
async function message(job:any) {
 let customer, heading, content, subject
 if(job.kind==='delivery_test') {
   heading='Booking system delivery test';subject=heading
   content='<p>This is the delivery test approved by Ed. It was sent through the booking system notification queue.</p><p>No appointment has been created and this email contains no patient information.</p>'
 } else if(job.kind==='package') {
   const cp=await first(`customer_packages?id=eq.${job.reference_id}`)
   if(!cp || cp.status!=='active') return null
   customer=await first(`customers?id=eq.${cp.customer_id}`)
   const pkg=await first(`packages?id=eq.${cp.package_id}`)
   heading='Your package is ready';subject=heading
   content=`<p>Hi ${esc(customer?.first_name || 'there')},</p><p>${esc(pkg.name)} · paid ${money(cp.amount_paid_pence)}.</p><p>Make your bookings before ${date(cp.expires_at)}. Appointments can take place after the package expires.</p><p><a href="https://book.ednicholls.com/?view=my-bookings">View your package and book</a></p>`
 } else {
   const b=await first(`bookings?id=eq.${job.reference_id}`)
   if(!b || (job.kind==='cancellation' ? b.status!=='cancelled' : b.status!=='confirmed')) return null
   if(job.kind==='reminder' && Date.parse(b.starts_at)<=Date.now()) return null
   customer=await first(`customers?id=eq.${b.customer_id}`)
   const service=await first(`services?id=eq.${b.service_id}`)
   heading=job.kind==='cancellation'?'Booking cancelled':job.kind==='reminder'?'Appointment reminder':'Booking confirmed'
   subject=`${heading} — ${date(b.starts_at)} at ${time(b.starts_at)}`
   const paid=(b.notes || '').startsWith('stripe:')
   content=`<p>${esc(service.name)}</p><p><strong>${date(b.starts_at)} at ${time(b.starts_at)}</strong> (UK time)<br>${service.duration_minutes} minutes</p>`
   if(job.kind==='cancellation') content+=`<p>${b.customer_package_id?'The session credit has been returned to your package.':paid?'For a card refund, please contact Ed.':''}</p>`
   else content+=`<p>${b.customer_package_id?'Paid with a package credit.':paid?'Paid online.':`${money(service.price_pence)} payable at the clinic.`}</p>`
   if(job.audience==='admin') content+=`<p>Patient: ${esc([customer?.first_name,customer?.last_name].filter(Boolean).join(' '))}</p><p><a href="https://book.ednicholls.com/admin">Open the admin dashboard for patient details and intake notes</a></p>`
   else if(job.kind!=='cancellation') content+=`<p>Tuscany Wharf, 4a Orsman Rd, London N1 5QJ</p><p>Try to arrive having eaten something light, and bring loose, comfortable clothing.</p><p>Please give at least 24 hours’ notice if you need to cancel.</p><p><a href="https://book.ednicholls.com/?cancel=${encodeURIComponent(b.cancellation_token)}">Cancel this appointment</a></p>`
 }
 const recipient=job.audience==='admin'?'acu@ednicholls.com':customer?.email
 if(!recipient || /@(noemail|deleted)\.local$/.test(recipient)) return null
 return {from:'Ed Nicholls Acupuncture <bookings@ednicholls.com>',to:[recipient],reply_to:'acu@ednicholls.com',subject,html:frame(heading,content)}
}
export async function handler(req:Request) {
 if(req.method!=='POST') return new Response('Method not allowed',{status:405})
 const supplied=req.headers.get('X-Internal-Token')
 if(!supplied) return new Response('Unauthorized',{status:401})
 const secret=await first('internal_settings?name=eq.notification_token&select=value')
 if(!secret || supplied!==secret.value) return new Response('Unauthorized',{status:401})
 // Delete authentication identities through the supported admin API; failed requests remain queued.
 const deletions=await db('account_deletion_requests?completed_at=is.null&limit=20')
 for(const deletion of deletions) {
   const key=env('SUPABASE_SERVICE_ROLE_KEY')
   const response=await fetch(`${env('SUPABASE_URL')}/auth/v1/admin/users/${deletion.user_id}`,{method:'DELETE',headers:{apikey:key,Authorization:`Bearer ${key}`}})
   await db(`account_deletion_requests?user_id=eq.${deletion.user_id}`,'PATCH',response.ok || response.status===404 ? {completed_at:new Date().toISOString(),last_error:null} : {last_error:`Auth deletion returned ${response.status}`})
 }
 const jobs=await rpc('claim_notifications',{})
 let sent=0, failed=0
 for(const job of jobs) {
   try {
     const body=await message(job)
     if(body) {
       const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${env('RESEND_API_KEY')}`,'Content-Type':'application/json','Idempotency-Key':`notification-${job.id}`},body:JSON.stringify(body)})
       if(!response.ok) throw new Error(`Email provider returned ${response.status}`)
     }
     await db(`notification_jobs?id=eq.${job.id}&attempts=eq.${job.attempts}`,'PATCH',{status:body?'sent':'skipped',sent_at:new Date().toISOString(),last_error:null})
     if(job.kind==='reminder') await db(`bookings?id=eq.${job.reference_id}`,'PATCH',{reminder_sent_at:new Date().toISOString()})
     sent++
   } catch {
     failed++
     await db(`notification_jobs?id=eq.${job.id}&attempts=eq.${job.attempts}`,'PATCH',{last_error:'Delivery not confirmed; retry scheduled.',next_attempt_at:new Date(Date.now()+Math.min(60,2**job.attempts)*60000).toISOString()})
   }
 }
 return new Response(JSON.stringify({sent,failed}),{headers:{'Content-Type':'application/json'}})
}
