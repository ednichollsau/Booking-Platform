// Appointment instants use UTC; clinic wall times always use Europe/London.
export const CLINIC_TZ = 'Europe/London'
export function dateKey(date = new Date()) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: CLINIC_TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(date)
}
export function wallTime(date, time = '00:00') {
  const target = Date.parse(`${date}T${time.length === 5 ? time + ':00' : time}Z`)
  if (!Number.isFinite(target)) throw new Error('Invalid appointment date')
  let instant = target
  for (let i = 0; i < 4; i++) {
    const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
      timeZone: CLINIC_TZ, year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23'
    }).formatToParts(new Date(instant)).map(p => [p.type, p.value]))
    const shown = Date.parse(`${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:${parts.second}Z`)
    const correction = target - shown
    if (!correction) return new Date(instant)
    instant += correction
  }
  throw new Error('This time does not exist because the clocks change')
}
// Calendar carriers preserve date arithmetic in the browser without treating it as an appointment instant.
export function calendarToday() {
  const [y, m, d] = dateKey().split('-').map(Number)
  return new Date(y, m - 1, d)
}
export function calendarKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`
}
export function clinicSlots({date, service, rules, overrides = [], bookings = [], now = new Date(), admin = false}) {
  if (!service) return []
  const key = typeof date === 'string' ? date : calendarKey(date)
  if (overrides.some(o => o.date === key && o.type === 'closed')) return []
  const dow = new Date(key + 'T12:00:00Z').getUTCDay()
  const earliest = +now + (admin ? 0 : (service.min_lead_hours || 0)) * 3600000
  const duration = service.duration_minutes * 60000
  const step = (service.slot_interval_minutes || service.duration_minutes) * 60000
  if (!(duration > 0 && step > 0)) return []
  const active = bookings.filter(b => !b.status || ['confirmed', 'completed'].includes(b.status))
  const slots = new Map()
  for (const rule of rules.filter(r => r.day_of_week === dow && (!r.service_id || r.service_id === service.id))) {
    const end = +wallTime(key, rule.end_time)
    for (let start = +wallTime(key, rule.start_time); start + duration <= end; start += step) {
      if (start < earliest) continue
      const overlaps = active.filter(b => Date.parse(b.starts_at) < start + duration && Date.parse(b.ends_at) > start)
      const same = overlaps.filter(b => b.service_id === service.id)
      // Count occupancy at every change point, rather than summing non-simultaneous overlaps.
      const points = [start, ...same.map(b => Date.parse(b.starts_at)).filter(t => t > start)]
      const full = points.some(t => same.filter(b => Date.parse(b.starts_at) <= t && Date.parse(b.ends_at) > t).length >= (service.concurrent_capacity || 1))
      const booked = overlaps.some(b => b.service_id !== service.id) || full || same.filter(b => Date.parse(b.starts_at) === start).length >= (service.start_capacity || 1)
      slots.set(start, {start: new Date(start), end: new Date(start + duration), booked, available: !booked})
    }
  }
  return [...slots.values()].sort((a,b) => a.start - b.start)
}
