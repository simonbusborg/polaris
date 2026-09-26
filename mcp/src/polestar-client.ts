// Polestar client — a port of Polaris's PolestarAPI.swift / PolestarGRPC.swift.
//
// Same flow as the app: OIDC discovery -> authorize (PKCE) -> scripted form
// login -> code exchange -> GraphQL (mystar-v2), plus the Volvo C3 gRPC
// battery service for charger connection and live charging power. Read-only:
// nothing in here sends a command to the car.
//
// Deliberately self-contained (node built-ins only, no MCP imports) so it can
// be lifted into its own package later.

import { createHash, randomBytes } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import http2 from "node:http2";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// ---------------------------------------------------------------- errors

export class PolestarError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
  }
}
/** Polestar ID refused the email/password. */
export class AuthFailedError extends PolestarError {}
/** The session is dead and a fresh login did not bring it back. */
export class SessionExpiredError extends PolestarError {}
/** Authenticated fine, but the car has reported nothing (asleep / offline). */
export class CarOfflineError extends PolestarError {}
/** Polestar changed a page or schema we depend on. */
export class ApiShapeError extends PolestarError {}
export class HttpError extends PolestarError {}

// ---------------------------------------------------------------- constants

const API_URL = "https://pc-api.polestar.com/eu-north-1/mystar-v2/";
const OIDC_PROVIDER = "https://polestarid.eu.polestar.com";
// The community-known OAuth client the Polestar web app uses (same as Polaris).
const CLIENT_ID = "l3oopkc_10";
const REDIRECT_URI = "https://www.polestar.com/sign-in-callback";
const SCOPE = "openid profile email customer:attributes";
const CNEPMOB_URL = "https://cnepmob.volvocars.com";
const GRPC_BATTERY_PATH = "/services.vehiclestates.battery.BatteryService/GetLatestBattery";
const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36";
/** Refresh this early, so a token never dies mid-request. */
const REFRESH_MARGIN_MS = 300_000;

// ---------------------------------------------------------------- public types

export interface Car {
  vin: string;
  modelName: string | null;
  modelYear: string | null;
  registrationNo: string | null;
}

export interface Battery {
  chargePercent: number;
  rangeKm: number;
  /** CHARGING_STATUS_ / CHARGING_STATUS_V2_ prefix stripped, e.g. "CHARGING", "IDLE", "DONE". */
  chargingStatus: string;
  minutesToFull: number | null;
  reportedAt: Date | null;
}

export interface Odometer {
  meters: number;
  reportedAt: Date | null;
}

export interface Telematics {
  vin: string;
  battery: Battery;
  odometer: Odometer | null;
}

/** From the gRPC battery service. Every field optional: the service is best-effort. */
export interface GrpcBatteryExtras {
  chargerConnection: "CONNECTED" | "DISCONNECTED" | "FAULT" | null;
  powerWatts: number | null;
  currentAmps: number | null;
  voltageVolts: number | null;
  chargingType: "AC" | "DC" | "WIRELESS" | null;
}

export interface StoredSession {
  email: string;
  refreshToken: string;
  accessToken?: string;
  /** Epoch ms. */
  expiresAt?: number;
}

export interface PolestarClientOptions {
  email: string;
  password: string;
  /** Pin a car; otherwise the first one on the account is used. */
  vin?: string;
  /** Where the session is cached. Keep it outside the repo. */
  tokenCachePath?: string;
  /** Injectable for tests. */
  fetch?: typeof fetch;
  now?: () => number;
  /** Injectable for tests; defaults to a real HTTP/2 call. */
  grpcBattery?: (vin: string, accessToken: string) => Promise<GrpcBatteryExtras>;
  log?: (message: string) => void;
}

export function defaultTokenCachePath(env: NodeJS.ProcessEnv = process.env): string {
  if (env.POLESTAR_TOKEN_CACHE) return env.POLESTAR_TOKEN_CACHE;
  const state = env.XDG_STATE_HOME || join(homedir(), ".local", "state");
  return join(state, "polestar-mcp", "tokens.json");
}

// ---------------------------------------------------------------- GraphQL documents

// Field names per Polestar's current schema (as in Polaris and pypolestar).
export const TELEMATICS_QUERY = `query CarTelematicsV2($vins: [String!]!) {
  carTelematicsV2(vins: $vins) {
    battery {
      vin
      batteryChargeLevelPercentage
      estimatedDistanceToEmptyKm
      chargingStatusV2
      estimatedChargingTimeToFullMinutes
      timestamp { seconds }
    }
    odometer {
      vin
      odometerMeters
      timestamp { seconds }
    }
  }
}`;

// Kept minimal on purpose: one rejected field fails the whole request.
export const CARS_QUERY = `query GetConsumerCarsV2 {
  getConsumerCarsV2 {
    vin
    modelName
    modelYear
    registrationNo
  }
}`;

// ---------------------------------------------------------------- client

interface GraphQLResult {
  status: number;
  json: unknown;
}

export class PolestarClient {
  private readonly opts: PolestarClientOptions;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;
  private readonly cachePath: string;
  private readonly log: (message: string) => void;

  private session: StoredSession | null = null;
  private sessionLoaded = false;
  private endpoints: { token: string; authorize: string } | null = null;
  private cars: Car[] | null = null;

  constructor(opts: PolestarClientOptions) {
    this.opts = opts;
    this.fetchImpl = opts.fetch ?? fetch;
    this.now = opts.now ?? Date.now;
    this.cachePath = opts.tokenCachePath ?? defaultTokenCachePath();
    this.log = opts.log ?? (() => {});
  }

  // ------------------------------------------------------------ public API

  async listCars(): Promise<Car[]> {
    if (this.cars) return this.cars;
    const json = await this.graphQL(CARS_QUERY);
    const list = dig(json, "data", "getConsumerCarsV2");
    if (!Array.isArray(list)) throw new ApiShapeError("Polestar's car list came back in an unexpected shape (getConsumerCarsV2 is not a list). The API may have changed.");
    this.cars = list.flatMap((c): Car[] => {
      const vin = str(dig(c, "vin"));
      if (!vin) return [];
      const year = dig(c, "modelYear");
      return [{
        vin,
        modelName: str(dig(c, "modelName")),
        modelYear: year == null ? null : String(year),
        registrationNo: str(dig(c, "registrationNo")),
      }];
    });
    if (this.cars.length === 0) throw new CarOfflineError("No cars are linked to this Polestar ID.");
    return this.cars;
  }

  /** The pinned car if POLESTAR_VIN matches, otherwise the first on the account. */
  async selectedCar(): Promise<Car> {
    const cars = await this.listCars();
    const wanted = this.opts.vin?.trim().toUpperCase();
    if (wanted) {
      const match = cars.find((c) => c.vin.toUpperCase() === wanted);
      if (match) return match;
      this.log(`POLESTAR_VIN is not on this account; using the first car instead`);
    }
    return cars[0]!;
  }

  async getTelematics(): Promise<{ car: Car; telematics: Telematics; extras: GrpcBatteryExtras | null }> {
    const car = await this.selectedCar();
    const json = await this.graphQL(TELEMATICS_QUERY, { vins: [car.vin] });
    const telematics = parseTelematics(json, car.vin);

    // Best-effort: charger connection and live power. Failure just means those fields are null.
    let extras: GrpcBatteryExtras | null = null;
    try {
      const token = await this.accessToken();
      extras = await (this.opts.grpcBattery ?? grpcBattery)(car.vin, token);
    } catch (e) {
      this.log(`gRPC battery extras unavailable: ${e instanceof Error ? e.message : "unknown error"}`);
    }
    return { car, telematics, extras };
  }

  // ------------------------------------------------------------ GraphQL with one retry

  /** POST a query. On a 401 the session is refreshed and the call retried exactly once. */
  private async graphQL(query: string, variables?: Record<string, unknown>): Promise<unknown> {
    let refreshed = false;
    for (;;) {
      const token = await this.accessToken();
      const { status, json } = await this.postGraphQL(query, variables, token);
      if (status === 401 || (status === 200 && hasAuthError(json))) {
        if (refreshed) {
          throw new SessionExpiredError("Polestar rejected the session even after a refresh. Sign in to Polestar again, or check that the password in POLESTAR_PASSWORD is current.");
        }
        refreshed = true;
        await this.refreshSession();
        continue;
      }
      if (status !== 200) throw new HttpError(`Polestar API returned HTTP ${status}${graphQLMessages(json)}`);
      const messages = graphQLMessages(json);
      if (messages) {
        if (/cannot query field|FieldUndefined|ValidationError|unknown (type|argument)/i.test(messages)) {
          throw new ApiShapeError(`Polestar rejected our query — the API schema has probably changed${messages}`);
        }
        throw new HttpError(`Polestar API error${messages}`);
      }
      return json;
    }
  }

  private async postGraphQL(query: string, variables: Record<string, unknown> | undefined, token: string): Promise<GraphQLResult> {
    let res: Response;
    try {
      res = await this.fetchImpl(API_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ query, ...(variables ? { variables } : {}) }),
      });
    } catch (e) {
      throw new HttpError(`Could not reach the Polestar API: ${e instanceof Error ? e.message : "network error"}`);
    }
    let json: unknown = null;
    try {
      json = await res.json();
    } catch {
      if (res.status === 200) throw new ApiShapeError("Polestar's API answered with something that isn't JSON.");
    }
    return { status: res.status, json };
  }

  // ------------------------------------------------------------ session handling

  private async accessToken(): Promise<string> {
    await this.loadSession();
    const s = this.session;
    if (s?.accessToken && s.expiresAt && s.expiresAt - this.now() > REFRESH_MARGIN_MS) return s.accessToken;
    await this.refreshSession();
    return this.session!.accessToken!;
  }

  private async loadSession(): Promise<void> {
    if (this.sessionLoaded) return;
    this.sessionLoaded = true;
    try {
      const stored = JSON.parse(await readFile(this.cachePath, "utf8")) as StoredSession;
      // A cache written for another account must never be reused.
      if (stored.email === this.opts.email && stored.refreshToken) this.session = stored;
    } catch {
      // No cache yet, or unreadable: start from a password login.
    }
  }

  private async saveSession(): Promise<void> {
    if (!this.session) return;
    try {
      await mkdir(dirname(this.cachePath), { recursive: true, mode: 0o700 });
      const tmp = `${this.cachePath}.${process.pid}.tmp`;
      await writeFile(tmp, JSON.stringify(this.session), { mode: 0o600 });
      await rename(tmp, this.cachePath);
    } catch (e) {
      this.log(`could not write the token cache: ${e instanceof Error ? e.message : "unknown error"}`);
    }
  }

  /**
   * Get a fresh access token: the refresh token first, and if Polestar says it
   * is dead (4xx — usually rotated away by a newer login) a full password login.
   */
  private async refreshSession(): Promise<void> {
    await this.loadSession();
    if (this.session?.refreshToken) {
      try {
        await this.refreshWithToken(this.session.refreshToken);
        return;
      } catch (e) {
        if (!(e instanceof SessionExpiredError)) throw e;
        this.log("refresh token rejected; signing in with the password");
        this.session = null;
      }
    }
    await this.passwordLogin();
  }

  private async discover(): Promise<{ token: string; authorize: string }> {
    if (this.endpoints) return this.endpoints;
    const res = await this.request(`${OIDC_PROVIDER}/.well-known/openid-configuration`);
    if (res.status !== 200) throw new HttpError(`Polestar ID discovery failed (HTTP ${res.status}).`);
    const json = safeJson(res.body);
    const token = str(dig(json, "token_endpoint"));
    const authorize = str(dig(json, "authorization_endpoint"));
    if (!token || !authorize) throw new ApiShapeError("Polestar ID's OIDC configuration is missing its token or authorization endpoint.");
    return (this.endpoints = { token, authorize });
  }

  private async refreshWithToken(refreshToken: string): Promise<void> {
    const { token } = await this.discover();
    const res = await this.request(token, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form({ grant_type: "refresh_token", client_id: CLIENT_ID, refresh_token: refreshToken }),
    });
    const json = safeJson(res.body);
    const access = str(dig(json, "access_token"));
    const expiresIn = num(dig(json, "expires_in"));
    if (res.status !== 200 || !access || expiresIn == null) {
      // 4xx means the token itself is dead; 5xx or a mangled body is Polestar having a bad minute.
      if (res.status >= 400 && res.status < 500) throw new SessionExpiredError("The stored Polestar session was rejected.");
      throw new HttpError(`Token refresh failed (HTTP ${res.status}${oauthError(json)}). Try again in a moment.`);
    }
    this.session = {
      email: this.opts.email,
      accessToken: access,
      // Polestar rotates refresh tokens; always keep the newest.
      refreshToken: str(dig(json, "refresh_token")) ?? refreshToken,
      expiresAt: this.now() + expiresIn * 1000,
    };
    await this.saveSession();
  }

  // ------------------------------------------------------------ password login (PKCE)

  private async passwordLogin(): Promise<void> {
    const { authorize, token } = await this.discover();
    const verifier = randomBytes(32).toString("base64url");
    const challenge = createHash("sha256").update(verifier).digest("base64url");
    const params = {
      client_id: CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: "code",
      scope: SCOPE,
      state: randomBytes(32).toString("base64url"),
      code_challenge: challenge,
      code_challenge_method: "S256",
      response_mode: "query",
    };
    const jar = new Map<string, string>();

    const authorizeUrl = `${authorize}?${new URLSearchParams(params)}`;
    const first = await this.followRedirects(authorizeUrl, { headers: { "User-Agent": USER_AGENT } }, jar);
    let code = first.code;

    if (!code) {
      const resumePath = extractResumePath(first.body);
      if (!resumePath) throw new ApiShapeError("Could not find Polestar's login form — Polestar may have changed their sign-in flow.");
      // Like pypolestar: the login POST goes to the resume path WITH the authorize params.
      const loginUrl = `${OIDC_PROVIDER}${resumePath}${resumePath.includes("?") ? "&" : "?"}${new URLSearchParams(params)}`;
      const login = await this.followRedirects(loginUrl, formPost({ "pf.username": this.opts.email, "pf.pass": this.opts.password }), jar);
      code = login.code;
      if (!code && login.uid) {
        // An extra confirmation step: POST it, and the code arrives on the next redirect.
        const confirm = await this.followRedirects(loginUrl, formPost({ "pf.submit": "true", subject: login.uid }), jar);
        code = confirm.code;
      }
      if (!code) throw new AuthFailedError("Polestar ID rejected the email or password. Check POLESTAR_EMAIL and POLESTAR_PASSWORD.");
    }

    const res = await this.request(token, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form({ grant_type: "authorization_code", client_id: CLIENT_ID, code, redirect_uri: REDIRECT_URI, code_verifier: verifier }),
    });
    const json = safeJson(res.body);
    const access = str(dig(json, "access_token"));
    const expiresIn = num(dig(json, "expires_in"));
    if (res.status !== 200 || !access || expiresIn == null) {
      throw new HttpError(`Polestar's token exchange failed (HTTP ${res.status}${oauthError(json)}).`);
    }
    this.session = {
      email: this.opts.email,
      accessToken: access,
      refreshToken: str(dig(json, "refresh_token")) ?? "",
      expiresAt: this.now() + expiresIn * 1000,
    };
    await this.saveSession();
  }

  /**
   * fetch has no cookie jar and follows redirects blindly, but the login is a
   * cookie-carrying redirect chain that ends on a callback URL we must not
   * fetch. So: follow by hand, carry cookies, and stop at the callback.
   */
  private async followRedirects(
    startUrl: string,
    init: RequestInit,
    jar: Map<string, string>,
  ): Promise<{ code: string | null; uid: string | null; body: string }> {
    let url = startUrl;
    let current = init;
    for (let hop = 0; hop < 10; hop++) {
      const cookie = [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
      const headers = { "User-Agent": USER_AGENT, ...(current.headers as Record<string, string> | undefined), ...(cookie ? { Cookie: cookie } : {}) };
      const res = await this.request(url, { ...current, headers, redirect: "manual" });
      for (const line of res.setCookies) {
        const [pair] = line.split(";");
        const eq = pair?.indexOf("=") ?? -1;
        if (pair && eq > 0) jar.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
      }
      const seen = paramsOf(url);
      if (res.status >= 300 && res.status < 400 && res.location) {
        const next = new URL(res.location, url).toString();
        if (next.startsWith(REDIRECT_URI)) {
          return { code: paramsOf(next).get("code"), uid: null, body: "" };
        }
        url = next;
        current = { method: "GET" }; // 302/303 after a POST become a GET
        continue;
      }
      return { code: null, uid: seen.get("uid"), body: res.body };
    }
    throw new ApiShapeError("Polestar's login redirected too many times.");
  }

  private async request(url: string, init: RequestInit = {}): Promise<{ status: number; body: string; location: string | null; setCookies: string[] }> {
    let res: Response;
    try {
      res = await this.fetchImpl(url, init);
    } catch (e) {
      throw new HttpError(`Could not reach Polestar: ${e instanceof Error ? e.message : "network error"}`);
    }
    return {
      status: res.status,
      body: await res.text(),
      location: res.headers.get("location"),
      setCookies: res.headers.getSetCookie?.() ?? [],
    };
  }
}

// ---------------------------------------------------------------- parsing

/** AppSync serialises the protobuf timestamp's int64 seconds as a number or a string — accept both. */
export function parseTimestamp(container: unknown): Date | null {
  const raw = dig(container, "timestamp", "seconds");
  const seconds = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw) : NaN;
  return Number.isFinite(seconds) && seconds > 0 ? new Date(seconds * 1000) : null;
}

export function parseTelematics(json: unknown, vin: string): Telematics {
  const root = dig(json, "data", "carTelematicsV2");
  if (root == null || typeof root !== "object") {
    throw new ApiShapeError("Polestar's telematics response has no carTelematicsV2 block. The API may have changed.");
  }
  const batteries = dig(root, "battery");
  if (!Array.isArray(batteries)) throw new ApiShapeError("Polestar's telematics response has no battery list. The API may have changed.");
  const battery = batteries[0];
  if (battery == null) {
    throw new CarOfflineError("Polestar has no battery report for this car. It is probably asleep or offline — try again after it has been driven or plugged in.");
  }
  const percent = num(dig(battery, "batteryChargeLevelPercentage"));
  const range = num(dig(battery, "estimatedDistanceToEmptyKm"));
  if (percent == null || range == null) {
    throw new ApiShapeError("Polestar's battery report is missing the charge level or range. The API may have changed.");
  }
  const odo = Array.isArray(dig(root, "odometer")) ? (dig(root, "odometer") as unknown[])[0] : null;
  const meters = num(dig(odo, "odometerMeters"));
  return {
    vin,
    battery: {
      chargePercent: percent,
      rangeKm: range,
      chargingStatus: (str(dig(battery, "chargingStatusV2")) ?? "UNKNOWN").replace(/^CHARGING_STATUS_(V2_)?/, ""),
      minutesToFull: num(dig(battery, "estimatedChargingTimeToFullMinutes")),
      reportedAt: parseTimestamp(battery),
    },
    odometer: meters == null ? null : { meters, reportedAt: parseTimestamp(odo) },
  };
}

export function extractResumePath(html: string): string | null {
  const patterns = [
    // Current login page embeds:  action: "/as/xxx/resume/as/authorization.ping"
    /(?:url|action):\s*"([^"]+)"/,
    /(?:resumePath|pf\.resumePath)\s*[:=]\s*['"]([^'"]+)['"]/,
    /action="([^"]+)"/,
    /action:\s*'([^']+)'/,
    /url:\s*'([^']+)'/,
    /\/as\/[a-zA-Z0-9\-_./]+/, // note the '.', or '.ping' gets truncated
  ];
  for (const [i, pattern] of patterns.entries()) {
    const match = pattern.exec(html);
    const value = match?.[1] ?? match?.[0];
    if (value && (i === patterns.length - 1 || value.startsWith("/"))) return value;
  }
  return null;
}

function hasAuthError(json: unknown): boolean {
  const errors = dig(json, "errors");
  return Array.isArray(errors) && errors.some((e) => /unauthori[sz]ed|unauthenticated|token/i.test(`${str(dig(e, "message")) ?? ""} ${str(dig(e, "errorType")) ?? ""}`));
}

/** ": message, message" or "" — never the raw body, which could echo tokens. */
function graphQLMessages(json: unknown): string {
  const errors = dig(json, "errors");
  if (!Array.isArray(errors)) return "";
  const messages = errors.map((e) => str(dig(e, "message"))).filter(Boolean);
  return messages.length ? `: ${messages.join(", ")}` : "";
}

function oauthError(json: unknown): string {
  const err = str(dig(json, "error"));
  return err ? `, ${err}` : "";
}

// ---------------------------------------------------------------- small helpers

function dig(value: unknown, ...path: string[]): unknown {
  let cur = value;
  for (const key of path) {
    if (cur == null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
}
const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
const form = (fields: Record<string, string>) => new URLSearchParams(fields).toString();
const formPost = (fields: Record<string, string>): RequestInit => ({
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: form(fields),
});
const paramsOf = (url: string) => new URL(url).searchParams;

// ---------------------------------------------------------------- gRPC battery (best-effort)

/** Just enough proto3 wire format for the battery service. */
export const protobuf = {
  varint(value: number): Buffer {
    const out: number[] = [];
    let v = value;
    do {
      let byte = v & 0x7f;
      v = Math.floor(v / 128);
      if (v !== 0) byte |= 0x80;
      out.push(byte);
    } while (v !== 0);
    return Buffer.from(out);
  },
  stringField(field: number, value: string): Buffer {
    const bytes = Buffer.from(value, "utf8");
    return Buffer.concat([this.varint(field * 8 + 2), this.varint(bytes.length), bytes]);
  },
  /** gRPC framing: flag byte (0 = uncompressed) + 4-byte big-endian length. */
  frame(message: Buffer): Buffer {
    const header = Buffer.alloc(5);
    header.writeUInt32BE(message.length, 1);
    return Buffer.concat([header, message]);
  },
  /** Flat parse of one message level. Unknown wire types end the parse rather than misreading bytes. */
  fields(data: Buffer): { number: number; wire: number; varint: number; data: Buffer }[] {
    const out: { number: number; wire: number; varint: number; data: Buffer }[] = [];
    let i = 0;
    const readVarint = (): number | null => {
      let result = 0;
      let shift = 0;
      while (i < data.length && shift < 56) {
        const b = data[i++]!;
        result += (b & 0x7f) * 2 ** shift;
        if (!(b & 0x80)) return result;
        shift += 7;
      }
      return null;
    };
    while (i < data.length) {
      const tag = readVarint();
      if (tag == null) break;
      const number = Math.floor(tag / 8);
      const wire = tag & 7;
      if (wire === 0) {
        const v = readVarint();
        if (v == null) return out;
        out.push({ number, wire, varint: v, data: Buffer.alloc(0) });
      } else if (wire === 1 || wire === 5) {
        const width = wire === 1 ? 8 : 4;
        if (i + width > data.length) return out;
        out.push({ number, wire, varint: 0, data: data.subarray(i, i + width) });
        i += width;
      } else if (wire === 2) {
        const len = readVarint();
        if (len == null || i + len > data.length) return out;
        out.push({ number, wire, varint: 0, data: data.subarray(i, i + len) });
        i += len;
      } else {
        return out;
      }
    }
    return out;
  },
};

/**
 * Battery (pccs.vehiclestates.entities.battery.v1) — the fields we use:
 * 6 = charger_connection_status, 10 = charging_power_watts, 11 = charging_current_amps,
 * 17 = charging_type, 18 = charging_voltage_volts.
 */
export function parseGrpcBattery(data: Buffer): GrpcBatteryExtras {
  const extras: GrpcBatteryExtras = { chargerConnection: null, powerWatts: null, currentAmps: null, voltageVolts: null, chargingType: null };
  for (const f of protobuf.fields(data)) {
    if (f.wire !== 0) continue;
    if (f.number === 6) extras.chargerConnection = ({ 1: "CONNECTED", 2: "DISCONNECTED", 3: "FAULT" } as const)[f.varint as 1 | 2 | 3] ?? null;
    else if (f.number === 10) extras.powerWatts = f.varint;
    else if (f.number === 11) extras.currentAmps = f.varint;
    else if (f.number === 18) extras.voltageVolts = f.varint;
    else if (f.number === 17) extras.chargingType = ({ 2: "AC", 3: "DC", 4: "WIRELESS" } as const)[f.varint as 2 | 3 | 4] ?? null;
  }
  return extras;
}

/** Pull the first message out of a gRPC response body and return the battery submessage. */
export function parseGrpcResponse(body: Buffer): GrpcBatteryExtras {
  if (body.length < 5 || body[0] !== 0) throw new ApiShapeError("gRPC: missing or compressed message frame");
  const length = body.readUInt32BE(1);
  if (body.length < 5 + length) throw new ApiShapeError("gRPC: truncated response frame");
  // GetBatteryResponse { id = 1, vin = 2, battery = 3 }
  const battery = protobuf.fields(body.subarray(5, 5 + length)).find((f) => f.number === 3 && f.wire === 2);
  if (!battery) throw new ApiShapeError("gRPC: no battery in response");
  return parseGrpcBattery(battery.data);
}

async function grpcBattery(vin: string, accessToken: string): Promise<GrpcBatteryExtras> {
  // The battery host is discovered, not fixed: cnepmob hands out the current C3 gRPC host and port.
  const discovery = await fetch(CNEPMOB_URL, { headers: { Accept: "application/volvo.cloud.cnepmob.v1+json" } });
  const c3 = dig(await discovery.json(), "c3");
  const host = str(dig(c3, "grpcHost"));
  const port = num(dig(c3, "grpcPort"));
  if (!discovery.ok || !host || !port) throw new ApiShapeError("C3 discovery failed");

  // GetBatteryRequest { id = 1 (a fresh UUID), vin = 2 }
  const message = protobuf.frame(Buffer.concat([protobuf.stringField(1, crypto.randomUUID()), protobuf.stringField(2, vin)]));
  const client = http2.connect(`https://${host}:${port}`);
  try {
    return await new Promise<GrpcBatteryExtras>((resolve, reject) => {
      client.on("error", reject);
      const req = client.request({
        ":method": "POST",
        ":path": GRPC_BATTERY_PATH,
        "content-type": "application/grpc",
        te: "trailers",
        authorization: `Bearer ${accessToken}`,
        vin,
      });
      req.setTimeout(15_000, () => req.close(http2.constants.NGHTTP2_CANCEL));
      const chunks: Buffer[] = [];
      let status = 0;
      req.on("response", (headers) => {
        status = Number(headers[":status"]);
        const grpcStatus = headers["grpc-status"];
        if (grpcStatus && grpcStatus !== "0") reject(new HttpError(`gRPC status ${String(grpcStatus)}`));
      });
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("error", reject);
      req.on("close", () => {
        if (status !== 200) return reject(new HttpError(`gRPC battery HTTP ${status}`));
        try {
          resolve(parseGrpcResponse(Buffer.concat(chunks)));
        } catch (e) {
          reject(e);
        }
      });
      req.end(message);
    });
  } finally {
    client.close();
  }
}
