import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it } from "vitest";
import {
  ApiShapeError, AuthFailedError, PolestarClient, SessionExpiredError, parseGrpcResponse, protobuf,
} from "../src/polestar-client.js";
import { CARS_RESPONSE, LOGIN_PAGE, OIDC_CONFIG, TELEMATICS_RESPONSE, TOKEN_RESPONSE } from "./fixtures.js";

const NOW = 1_790_000_000_000;
const reply = (body: unknown, init: ResponseInit = {}) =>
  new Response(typeof body === "string" ? body : JSON.stringify(body), { status: 200, ...init });

interface Call { url: string; method: string; body: string; auth: string | null }

/** A fetch that answers by URL and records every call. Handlers may be a queue for repeat calls. */
function mockFetch(routes: Record<string, (call: Call) => Response>) {
  const calls: Call[] = [];
  const impl = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = String(input);
    const headers = new Headers(init.headers);
    const call = { url, method: init.method ?? "GET", body: String(init.body ?? ""), auth: headers.get("authorization") };
    calls.push(call);
    const key = Object.keys(routes).find((k) => url.startsWith(k));
    if (!key) throw new Error(`unmocked ${url}`);
    return routes[key]!(call);
  }) as typeof fetch;
  return { impl, calls };
}

let dir: string;
let cache: string;
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), "polestar-mcp-"));
  cache = join(dir, "tokens.json");
});

const client = (fetchImpl: typeof fetch, extra = {}) =>
  new PolestarClient({ email: "me@example.com", password: "hunter2", tokenCachePath: cache, fetch: fetchImpl, now: () => NOW, grpcBattery: async () => { throw new Error("no grpc in tests"); }, ...extra });

const graphql = (handler: (call: Call) => Response) => ({
  "https://pc-api.polestar.com/": (call: Call) => handler(call),
});
const discovery = { "https://polestarid.eu.polestar.com/.well-known": () => reply(OIDC_CONFIG) };

describe("token refresh", () => {
  it("uses a cached, still-valid access token without touching the token endpoint", async () => {
    await writeFile(cache, JSON.stringify({ email: "me@example.com", refreshToken: "r1", accessToken: "cached", expiresAt: NOW + 3_600_000 }));
    const { impl, calls } = mockFetch(graphql((c) => reply(c.body.includes("GetConsumerCarsV2") ? CARS_RESPONSE : TELEMATICS_RESPONSE)));
    const { telematics } = await client(impl).getTelematics();
    expect(telematics.battery.rangeKm).toBe(281);
    expect(calls.every((c) => c.auth === "Bearer cached")).toBe(true);
  });

  it("refreshes an expiring token, sends the new one, and stores the rotated refresh token", async () => {
    await writeFile(cache, JSON.stringify({ email: "me@example.com", refreshToken: "r1", accessToken: "old", expiresAt: NOW + 60_000 }));
    const { impl, calls } = mockFetch({
      ...discovery,
      "https://polestarid.eu.polestar.com/as/token": () => reply(TOKEN_RESPONSE),
      ...graphql((c) => reply(c.body.includes("GetConsumerCarsV2") ? CARS_RESPONSE : TELEMATICS_RESPONSE)),
    });
    await client(impl).getTelematics();
    const refresh = calls.find((c) => c.url.includes("/as/token"))!;
    expect(refresh.body).toContain("grant_type=refresh_token");
    expect(refresh.body).toContain("refresh_token=r1");
    expect(calls.filter((c) => c.url.includes("pc-api")).every((c) => c.auth === "Bearer access-2")).toBe(true);
    expect(JSON.parse(await readFile(cache, "utf8"))).toMatchObject({ refreshToken: "refresh-2", accessToken: "access-2" });
  });

  it("on a 401 refreshes once and retries once", async () => {
    await writeFile(cache, JSON.stringify({ email: "me@example.com", refreshToken: "r1", accessToken: "stale", expiresAt: NOW + 3_600_000 }));
    let refreshes = 0;
    const { impl, calls } = mockFetch({
      ...discovery,
      "https://polestarid.eu.polestar.com/as/token": () => (refreshes++, reply(TOKEN_RESPONSE)),
      ...graphql((c) => c.auth === "Bearer stale" ? reply({}, { status: 401 }) : reply(c.body.includes("GetConsumerCarsV2") ? CARS_RESPONSE : TELEMATICS_RESPONSE)),
    });
    await client(impl).getTelematics();
    expect(refreshes).toBe(1);
    expect(calls.filter((c) => c.auth === "Bearer stale")).toHaveLength(1);
  });

  it("gives up with SessionExpiredError when the retry is also rejected", async () => {
    await writeFile(cache, JSON.stringify({ email: "me@example.com", refreshToken: "r1", accessToken: "a", expiresAt: NOW + 3_600_000 }));
    const { impl, calls } = mockFetch({
      ...discovery,
      "https://polestarid.eu.polestar.com/as/token": () => reply(TOKEN_RESPONSE),
      ...graphql(() => reply({}, { status: 401 })),
    });
    await expect(client(impl).getTelematics()).rejects.toThrow(SessionExpiredError);
    expect(calls.filter((c) => c.url.includes("pc-api"))).toHaveLength(2);
  });

  it("ignores a cache written for a different account", async () => {
    await writeFile(cache, JSON.stringify({ email: "someone@else.com", refreshToken: "theirs", accessToken: "theirs", expiresAt: NOW + 3_600_000 }));
    const { impl, calls } = mockFetch({
      ...discovery,
      "https://polestarid.eu.polestar.com/as/authorization.oauth2": () => reply({}, { status: 500 }),
    });
    await expect(client(impl).getTelematics()).rejects.toThrow();
    expect(calls.some((c) => c.auth === "Bearer theirs")).toBe(false);
  });
});

describe("password login", () => {
  const loginRoutes = (loginResponse: () => Response) => ({
    ...discovery,
    "https://polestarid.eu.polestar.com/as/authorization.oauth2": () => reply(LOGIN_PAGE, { headers: { "set-cookie": "PF=sess; Path=/" } }),
    "https://polestarid.eu.polestar.com/as/abc123/resume": loginResponse,
    "https://polestarid.eu.polestar.com/as/token": () => reply(TOKEN_RESPONSE),
    ...graphql((c) => reply(c.body.includes("GetConsumerCarsV2") ? CARS_RESPONSE : TELEMATICS_RESPONSE)),
  });

  it("falls back to PKCE login when the refresh token is dead, carrying the session cookie", async () => {
    await writeFile(cache, JSON.stringify({ email: "me@example.com", refreshToken: "dead" }));
    let tokenCalls = 0;
    const routes = loginRoutes(() => reply("", { status: 302, headers: { location: "https://www.polestar.com/sign-in-callback?code=abc" } }));
    routes["https://polestarid.eu.polestar.com/as/token"] = () => (tokenCalls++ === 0 ? reply({ error: "invalid_grant" }, { status: 400 }) : reply(TOKEN_RESPONSE));
    const { impl, calls } = mockFetch(routes);
    await client(impl).getTelematics();

    const exchange = calls.filter((c) => c.url.includes("/as/token")).at(-1)!;
    expect(exchange.body).toContain("grant_type=authorization_code");
    expect(exchange.body).toContain("code=abc");
    expect(exchange.body).toContain("code_verifier=");
    const authorize = calls.find((c) => c.url.includes("authorization.oauth2"))!;
    expect(authorize.url).toContain("code_challenge_method=S256");
    const post = calls.find((c) => c.url.includes("/resume/"))!;
    expect(post.body).toContain("pf.username=me%40example.com");
  });

  it("reports bad credentials plainly, without echoing the password", async () => {
    const { impl } = mockFetch(loginRoutes(() => reply("<html>ERR001</html>")));
    const err = await client(impl).getTelematics().catch((e) => e);
    expect(err).toBeInstanceOf(AuthFailedError);
    expect(err.message).not.toContain("hunter2");
  });

  it("flags a login page it cannot parse as an API change", async () => {
    const routes = loginRoutes(() => reply(""));
    routes["https://polestarid.eu.polestar.com/as/authorization.oauth2"] = () => reply("<html>nothing here</html>");
    await expect(client(mockFetch(routes).impl).getTelematics()).rejects.toThrow(ApiShapeError);
  });
});

describe("car selection and API errors", () => {
  const authed = async () => writeFile(cache, JSON.stringify({ email: "me@example.com", refreshToken: "r", accessToken: "a", expiresAt: NOW + 3_600_000 }));
  const api = () => mockFetch(graphql((c) => reply(c.body.includes("GetConsumerCarsV2") ? CARS_RESPONSE : TELEMATICS_RESPONSE)));

  it("defaults to the first car, or the pinned VIN", async () => {
    await authed();
    expect((await client(api().impl).selectedCar()).vin).toBe("YSMFAKEVIN0000001");
    expect((await client(api().impl, { vin: "ysmfakevin0000002" }).selectedCar()).modelName).toBe("Polestar 2");
  });

  it("maps a GraphQL validation error to an API-shape error", async () => {
    await authed();
    const { impl } = mockFetch(graphql(() => reply({ errors: [{ message: "Cannot query field \"foo\" on type \"Battery\"" }] })));
    await expect(client(impl).listCars()).rejects.toThrow(ApiShapeError);
  });
});

describe("gRPC battery decoding", () => {
  it("decodes connection, power, current, voltage and type from a framed response", () => {
    const varintField = (n: number, v: number) => Buffer.concat([protobuf.varint(n * 8), protobuf.varint(v)]);
    const battery = Buffer.concat([varintField(6, 1), varintField(10, 10_400), varintField(11, 16), varintField(17, 2), varintField(18, 650)]);
    const response = Buffer.concat([protobuf.stringField(1, "id"), protobuf.stringField(2, "vin"), Buffer.concat([protobuf.varint(3 * 8 + 2), protobuf.varint(battery.length), battery])]);
    expect(parseGrpcResponse(protobuf.frame(response))).toEqual({ chargerConnection: "CONNECTED", powerWatts: 10_400, currentAmps: 16, voltageVolts: 650, chargingType: "AC" });
  });

  it("rejects a truncated frame", () => {
    expect(() => parseGrpcResponse(Buffer.from([0, 0, 0, 0, 9, 1]))).toThrow(/truncated/);
  });
});
