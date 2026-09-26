# Polestar MCP server

A local, **read-only** MCP server that lets Claude ask your Polestar about its battery, range, charging and odometer. It talks to Polestar the same way the Polaris menu bar app does, and `src/polestar-client.ts` is a self-contained port of that flow (Polestar ID PKCE login, token refresh, GraphQL, and the gRPC battery service).

Unofficial and undocumented API: it can change without notice. Nothing here sends a command to the car.

## Tools

| Tool | Returns |
| --- | --- |
| `get_status` | Battery %, estimated range (km), charging state, charging power (kW), time to full, plugged in or not, plus the car's own data timestamp and age |
| `get_odometer` | Odometer in km with its timestamp |
| `check_trip` | Takes `destination`, `distance_km` and optional `return_trip`. Returns current range, a verdict (`OK`, `TIGHT`, `NO`) with a 15% buffer, the margin in km and an estimated battery at the end. Claude supplies the distance; the tool only does the range maths |

Every response carries `data_timestamp` and `data_age_minutes` (from the car, not from when we asked) and a `stale` flag past six hours.

### Not available

- **`get_location`**: Polaris never reads the car's position, so there is no known query to port, and one guessed against an unseen schema would fail. Needs someone with a car to find where the position lives (the gRPC vehicle-state services are the likely place).
- **`get_charging_history`**: same: nothing in Polaris or the API surface it uses (tracked as a Polaris roadmap item).

## Setup

Node 22.9 or newer.

```sh
cd mcp
npm install
npm run build
cp .env.example .env   # fill in POLESTAR_EMAIL and POLESTAR_PASSWORD
```

| Variable | |
| --- | --- |
| `POLESTAR_EMAIL`, `POLESTAR_PASSWORD` | Polestar ID credentials (required) |
| `POLESTAR_VIN` | Optional. Pin a car; otherwise the first car on the account |
| `POLESTAR_TOKEN_CACHE` | Optional. Defaults to `~/.local/state/polestar-mcp/tokens.json` (mode 0600, outside the repo) |

Only the refresh and access tokens are cached, never the password. Tokens are refreshed automatically; if the refresh token has been rejected the server signs in again with the password. A failed call is retried at most once, after a refresh.

Note: Polestar rotates refresh tokens, and a fresh login can invalidate the session the Polaris app holds. Polaris then signs itself in again, but it is worth knowing if you see it re-authenticate.

## Claude Desktop

Add to `claude_desktop_config.json`, using the absolute path to `dist/index.js`:

```json
{
  "mcpServers": {
    "polestar": {
      "command": "node",
      "args": ["/absolute/path/to/Polaris/mcp/dist/index.js"],
      "env": {
        "POLESTAR_EMAIL": "you@example.com",
        "POLESTAR_PASSWORD": "your-password",
        "POLESTAR_VIN": ""
      }
    }
  }
}
```

Restart Claude Desktop after editing. Rebuild (`npm run build`) after changing the source.

## Testing

```sh
npm test          # vitest, mocked responses, no network
npm run typecheck
npx @modelcontextprotocol/inspector node --env-file=.env dist/index.js
```

The inspector opens a local web UI: connect, open **Tools**, and run `get_status` or `check_trip` against your real car.

## Scripts

`npm run build` compiles to `dist/`. `npm run dev` runs from source with `tsx` and loads `.env`. `npm start` runs the build. `npm test` runs vitest.

## Error messages

Auth failure (bad email or password), expired session (rejected even after a refresh), car asleep or offline (no battery report), API shape change (a page or field Polestar changed) and network errors each get their own message, so Claude can tell you which one it is.

## Possible next steps

Polaris is read-only by design, and so is this. These are not implemented:

- **Remote commands** (climate on/off, lock/unlock, honk and flash, start/stop charging). Polaris has none of these, so there is no call in this codebase to port; they would need to be found in the Polestar app's traffic first, and deserve their own confirmation flow.
- `get_location` and `get_charging_history`, once the data source is found.
- Climate / preconditioning status, service and fluid warnings (Polaris already reads the latter via the `health` block).
