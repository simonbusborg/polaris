#!/usr/bin/env node
// Read-only Polestar MCP server over stdio. stdout belongs to the protocol,
// so all logging goes to stderr — and never includes credentials or tokens.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { PolestarClient, PolestarError } from "./polestar-client.js";
import { buildOdometer, buildStatus, buildTripCheck } from "./tools.js";

const email = process.env.POLESTAR_EMAIL;
const password = process.env.POLESTAR_PASSWORD;
if (!email || !password) {
  console.error("polestar-mcp: set POLESTAR_EMAIL and POLESTAR_PASSWORD (see .env.example).");
  process.exit(1);
}

const client = new PolestarClient({
  email,
  password,
  vin: process.env.POLESTAR_VIN || undefined,
  log: (m) => console.error(`polestar-mcp: ${m}`),
});

const server = new McpServer({ name: "polestar", version: "0.1.0" });
const readOnly = { readOnlyHint: true, openWorldHint: true } as const;

const json = (value: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }] });

/** Turn a client error into a message Claude can relay; unknown errors stay generic so nothing leaks. */
async function run(fn: () => Promise<unknown>) {
  try {
    return json(await fn());
  } catch (e) {
    const message = e instanceof PolestarError ? e.message : "Unexpected error talking to Polestar.";
    if (!(e instanceof PolestarError)) console.error("polestar-mcp: unexpected error:", e instanceof Error ? e.name : typeof e);
    return { isError: true, content: [{ type: "text" as const, text: `${e instanceof PolestarError ? e.name.replace(/Error$/, "") + ": " : ""}${message}` }] };
  }
}

server.registerTool(
  "get_status",
  {
    title: "Car status",
    description: "Battery %, estimated range, charging state, charging power, time to full and whether the car is plugged in. Includes the timestamp the car last reported so staleness is visible.",
    annotations: readOnly,
  },
  () => run(async () => {
    const { car, telematics, extras } = await client.getTelematics();
    return buildStatus(car, telematics, extras);
  }),
);

server.registerTool(
  "get_odometer",
  {
    title: "Odometer",
    description: "Total distance driven, in km, with the timestamp of the car's last odometer report.",
    annotations: readOnly,
  },
  () => run(async () => {
    const { car, telematics } = await client.getTelematics();
    return buildOdometer(car, telematics);
  }),
);

server.registerTool(
  "check_trip",
  {
    title: "Check a trip against range",
    description: "Compares the car's current range with a trip, keeping a 15% buffer. You supply distance_km (estimate it yourself); this tool does not look up routes. Returns OK, TIGHT (within range but eats the buffer) or NO.",
    inputSchema: {
      destination: z.string().min(1).describe("Where the trip goes; echoed back for context only"),
      distance_km: z.number().positive().describe("One-way distance in km"),
      return_trip: z.boolean().default(false).describe("True if the car must also come back without charging"),
    },
    annotations: readOnly,
  },
  ({ destination, distance_km, return_trip }) => run(async () => {
    const { telematics } = await client.getTelematics();
    return buildTripCheck({
      destination,
      distanceKm: distance_km,
      returnTrip: return_trip,
      rangeKm: telematics.battery.rangeKm,
      batteryPercent: telematics.battery.chargePercent,
      reportedAt: telematics.battery.reportedAt,
    });
  }),
);

await server.connect(new StdioServerTransport());
