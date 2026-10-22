import test from 'node:test'
import assert from 'node:assert/strict'
import {wallTime, dateKey, clinicSlots} from '../clinic-time.mjs'
const service = {id:'multi',duration_minutes:45,slot_interval_minutes:15,concurrent_capacity:3,start_capacity:1,min_lead_hours:0}
const rules = [{service_id:'multi',day_of_week:4,start_time:'18:00:00',end_time:'21:00:00'}]
test('London times follow spring and autumn clock changes across years', () => {
  for (const [day, hour] of [['2026-03-28','18'],['2026-03-29','17'],['2026-10-24','17'],['2026-10-25','18'],['2027-03-28','17'],['2027-10-31','18']]) {
    assert.equal(wallTime(day,'18:00').toISOString(), `${day}T${hour}:00:00.000Z`)
  }
  assert.throws(() => wallTime('2026-03-29','01:30'), /does not exist/)
  assert.equal(dateKey(new Date('2026-07-01T23:30:00Z')), '2026-07-02')
})
test('Thursday opening is 18:00 London, last appointment 20:15', () => {
  const slots = clinicSlots({date:'2026-10-22',service,rules,now:new Date('2026-10-20')})
  assert.equal(slots.length,10)
  assert.equal(slots[0].start.toISOString(),'2026-10-22T17:00:00.000Z')
  assert.equal(slots.at(-1).start.toISOString(),'2026-10-22T19:15:00.000Z')
})
test('staggering permits overlaps but prevents duplicate starts and other services', () => {
  const bookings = [{service_id:'multi',starts_at:'2026-10-22T17:00Z',ends_at:'2026-10-22T17:45Z'}]
  const slots = clinicSlots({date:'2026-10-22',service,rules,bookings,now:new Date('2026-10-20')})
  assert.equal(slots[0].booked,true)
  assert.equal(slots[1].booked,false)
  assert.equal(clinicSlots({date:'2026-10-22',service,rules,bookings:[{...bookings[0],service_id:'private'}],now:new Date('2026-10-20')})[1].booked,true)
})
test('closures and configurable notice periods apply', () => {
  assert.equal(clinicSlots({date:'2026-10-22',service,rules,overrides:[{date:'2026-10-22',type:'closed'}]}).length,0)
  assert.equal(clinicSlots({date:'2026-10-22',service:{...service,min_lead_hours:24},rules,now:new Date('2026-10-22T10:00Z')}).length,0)
})
