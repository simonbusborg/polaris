// Response shapes as Polaris decodes them (PolestarAPI.swift). Values are made up.

export const CARS_RESPONSE = {
  data: {
    getConsumerCarsV2: [
      { vin: "YSMFAKEVIN0000001", modelName: "Polestar 4", modelYear: "2026", registrationNo: "AB12345" },
      { vin: "YSMFAKEVIN0000002", modelName: "Polestar 2", modelYear: 2023, registrationNo: null },
    ],
  },
};

// AppSync serialises int64 seconds as a number or a string; the fixture uses both.
export const TELEMATICS_RESPONSE = {
  data: {
    carTelematicsV2: {
      battery: [{
        vin: "YSMFAKEVIN0000001",
        batteryChargeLevelPercentage: 64.5,
        estimatedDistanceToEmptyKm: 281,
        chargingStatusV2: "CHARGING_STATUS_V2_CHARGING",
        estimatedChargingTimeToFullMinutes: 95,
        timestamp: { seconds: 1_790_000_000 },
      }],
      odometer: [{ vin: "YSMFAKEVIN0000001", odometerMeters: 12_345_678, timestamp: { seconds: "1789999000" } }],
    },
  },
};

export const EMPTY_TELEMATICS_RESPONSE = { data: { carTelematicsV2: { battery: [], odometer: [] } } };

export const TOKEN_RESPONSE = { access_token: "access-2", refresh_token: "refresh-2", expires_in: 3600, token_type: "Bearer" };

export const OIDC_CONFIG = {
  token_endpoint: "https://polestarid.eu.polestar.com/as/token.oauth2",
  authorization_endpoint: "https://polestarid.eu.polestar.com/as/authorization.oauth2",
};

export const LOGIN_PAGE = `<html><script>var cfg = { url: "/as/abc123/resume/as/authorization.ping" };</script></html>`;
