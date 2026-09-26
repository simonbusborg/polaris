import { describe, expect, it } from "vitest";
import { buildOdometer, buildStatus, buildTripCheck } from "../src/tools.js";
import { CarOfflineError, parseTelematics } from "../src/polestar-client.js";
import { EMPTY_TELEMATICS_RESPONSE, TELEMATICS_RESPONSE } from "./fixtures.js";

const car = { vin: "YSMFAKEVIN0000001", modelName: "Polestar 4", modelYear: "2026", registrationNo: null };
const trip = (over: Partial<Parameters<typeof buildTripCheck>[0]> = {}) =>
  buildTripCheck({ destination: "Aarhus", distanceKm: 100, returnTrip: false, rangeKm: 200, batteryPercent: 60, reportedAt: null, ...over });

describe("check_trip maths", () => {
  it("is OK when range covers distance plus 15%", () => {
    const r = trip({ distanceKm: 100, rangeKm: 115 });
    expect(r.required_range_with_buffer_km).toBe(115);
    expect(r.margin_km).toBe(0);
    expect(r.verdict).toBe("OK");
  });

  it("is TIGHT when the trip fits but not the buffer", () => {
    const r = trip({ distanceKm: 100, rangeKm: 110 });
    expect(r.verdict).toBe("TIGHT");
    expect(r.margin_km).toBe(-5);
  });

  it("is NO when the trip alone exceeds range, and says how short", () => {
    const r = trip({ distanceKm: 100, rangeKm: 99 });
    expect(r.verdict).toBe("NO");
    expect(r.summary).toContain("16 km"); // 115 - 99
  });

  it("doubles the distance for a return trip", () => {
    const r = trip({ distanceKm: 100, rangeKm: 200, returnTrip: true });
    expect(r.total_distance_km).toBe(200);
    expect(r.required_range_with_buffer_km).toBe(230);
    expect(r.verdict).toBe("TIGHT");
  });

  it("estimates the battery left at the end linearly", () => {
    expect(trip({ distanceKm: 100, rangeKm: 200, batteryPercent: 60 }).estimated_battery_at_end_percent).toBe(30);
  });

  it("reports staleness from the car's timestamp", () => {
    const now = new Date("2026-09-26T12:00:00Z");
    const r = trip({ reportedAt: new Date("2026-09-26T03:00:00Z"), now });
    expect(r.data_age_minutes).toBe(540);
    expect(r.stale).toBe(true);
  });
});

describe("status and odometer shaping", () => {
  const t = parseTelematics(TELEMATICS_RESPONSE, car.vin);

  it("shapes a charging car with gRPC extras", () => {
    const s = buildStatus(car, t, { chargerConnection: "CONNECTED", powerWatts: 10_400, currentAmps: 16, voltageVolts: 650, chargingType: "AC" }, new Date(1_790_000_600_000));
    expect(s).toMatchObject({ battery_percent: 64.5, estimated_range_km: 281, charging_state: "CHARGING", plugged_in: true, charging_power_kw: 10.4, time_to_full_minutes: 95, data_age_minutes: 10, stale: false });
  });

  it("infers plugged_in from the status when gRPC is down", () => {
    const s = buildStatus(car, t, null);
    expect(s.plugged_in).toBe(true);
    expect(s.charging_power_kw).toBeNull();
    expect(s.note).toContain("inferred");
  });

  it("converts odometer metres to km", () => {
    expect(buildOdometer(car, t, new Date(1_790_000_000_000)).odometer_km).toBe(12345.7);
  });
});

describe("parseTelematics", () => {
  it("accepts string or numeric timestamp seconds", () => {
    const t = parseTelematics(TELEMATICS_RESPONSE, car.vin);
    expect(t.battery.reportedAt?.getTime()).toBe(1_790_000_000_000);
    expect(t.odometer?.reportedAt?.getTime()).toBe(1_789_999_000_000);
  });

  it("reports an asleep car when there is no battery record", () => {
    expect(() => parseTelematics(EMPTY_TELEMATICS_RESPONSE, car.vin)).toThrow(CarOfflineError);
  });

  it("flags a changed shape", () => {
    expect(() => parseTelematics({ data: { somethingElse: 1 } }, car.vin)).toThrow(/API may have changed/);
  });
});
