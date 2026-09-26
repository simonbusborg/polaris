// Pure shaping of client data into the JSON the tools return. No I/O here, so
// the maths is testable without a car.

import type { Car, GrpcBatteryExtras, Telematics } from "./polestar-client.js";

/** check_trip keeps this much range in reserve on top of the distance. */
export const TRIP_BUFFER = 0.15;
/** Beyond this the car's data is old enough to flag as stale. */
const STALE_AFTER_MINUTES = 6 * 60;

const round = (n: number, digits = 0) => Math.round(n * 10 ** digits) / 10 ** digits;

function freshness(reportedAt: Date | null, now: Date) {
  if (!reportedAt) return { data_timestamp: null, data_age_minutes: null, stale: null };
  const age = Math.max(0, Math.round((now.getTime() - reportedAt.getTime()) / 60_000));
  return { data_timestamp: reportedAt.toISOString(), data_age_minutes: age, stale: age > STALE_AFTER_MINUTES };
}

function carLabel(car: Car) {
  return { vin: car.vin, model: [car.modelName, car.modelYear].filter(Boolean).join(" ") || null };
}

export function buildStatus(car: Car, t: Telematics, extras: GrpcBatteryExtras | null, now = new Date()) {
  const b = t.battery;
  const charging = b.chargingStatus === "CHARGING";
  // Without the gRPC service, only a charging/done/scheduled status proves a cable is in.
  const inferredPlugged = ["CHARGING", "DONE", "SCHEDULED"].includes(b.chargingStatus) ? true : null;
  const pluggedIn = extras?.chargerConnection ? extras.chargerConnection === "CONNECTED" : inferredPlugged;

  return {
    car: carLabel(car),
    battery_percent: round(b.chargePercent, 1),
    estimated_range_km: b.rangeKm,
    charging_state: b.chargingStatus,
    plugged_in: pluggedIn,
    charging_power_kw: charging && extras?.powerWatts != null ? round(extras.powerWatts / 1000, 1) : charging ? null : 0,
    charging_type: extras?.chargingType ?? null,
    time_to_full_minutes: charging ? b.minutesToFull : null,
    ...freshness(b.reportedAt, now),
    ...(extras ? {} : { note: "Charger connection and live power come from a separate service that was unreachable; plugged_in is inferred from the charging state." }),
  };
}

export function buildOdometer(car: Car, t: Telematics, now = new Date()) {
  if (!t.odometer) return { car: carLabel(car), odometer_km: null, note: "Polestar returned no odometer reading for this car." };
  return {
    car: carLabel(car),
    odometer_km: round(t.odometer.meters / 1000, 1),
    ...freshness(t.odometer.reportedAt, now),
  };
}

export type TripVerdict = "OK" | "TIGHT" | "NO";

/**
 * Range vs. a trip, with a 15% buffer. The distance is Claude's estimate; the
 * range is the car's own, which real-world consumption (speed, cold, load) can
 * miss by a lot — so a verdict is guidance, not a guarantee.
 */
export function buildTripCheck(input: {
  destination: string;
  distanceKm: number;
  returnTrip: boolean;
  rangeKm: number;
  batteryPercent: number;
  reportedAt: Date | null;
  now?: Date;
}) {
  const required = input.distanceKm * (input.returnTrip ? 2 : 1);
  const withBuffer = required * (1 + TRIP_BUFFER);
  const margin = input.rangeKm - withBuffer;
  const verdict: TripVerdict = margin >= 0 ? "OK" : input.rangeKm >= required ? "TIGHT" : "NO";

  const summary = {
    OK: `Enough range, with the ${TRIP_BUFFER * 100}% buffer to spare.`,
    TIGHT: `The trip is within range, but it eats into the ${TRIP_BUFFER * 100}% buffer. Charge first or plan a charging stop.`,
    NO: `Not enough range. A charging stop is needed, short by about ${Math.ceil(withBuffer - input.rangeKm)} km including the buffer.`,
  }[verdict];

  // Linear guess: same consumption per km as the car's own range estimate implies.
  const remaining = input.rangeKm - required;
  const arrival = input.rangeKm > 0 ? round(Math.max(0, (input.batteryPercent * remaining) / input.rangeKm)) : 0;

  return {
    destination: input.destination,
    verdict,
    summary,
    current_range_km: input.rangeKm,
    battery_percent: round(input.batteryPercent, 1),
    trip_distance_km: round(input.distanceKm, 1),
    return_trip: input.returnTrip,
    total_distance_km: round(required, 1),
    buffer_percent: TRIP_BUFFER * 100,
    required_range_with_buffer_km: round(withBuffer, 1),
    margin_km: round(margin, 1),
    estimated_battery_at_end_percent: verdict === "NO" ? 0 : arrival,
    ...freshness(input.reportedAt, input.now ?? new Date()),
    caveat: input.returnTrip
      ? "Round trip assumes no charging at the destination. Range is the car's own estimate; motorway speed and cold weather reduce it."
      : "Range is the car's own estimate; motorway speed and cold weather reduce it.",
  };
}
