// Mail-reading primitive for browser specs.
//
// Playwright has no email API, so signup/verification flows that need a code
// emailed to the user (Ente's OTT, magic links, etc.) read it out-of-band from
// inbucket here. The test runner exports `INBUCKET_URL` into every Playwright
// step's environment when inbucket is installed (see `run_browser_step` in
// crates/ryra-test/src/runner.rs) — specs never hard-code inbucket's port or
// the on-disk .env path.

interface MessageHeader {
  id: string;
  subject: string;
  date: string;
}

interface Message {
  subject: string;
  body: { text: string; html: string };
}

function baseUrl(): string {
  const url = process.env.INBUCKET_URL;
  if (!url) {
    throw new Error(
      "INBUCKET_URL is not set — install a service with --smtp=inbucket so the " +
        "test runner can expose inbucket to this spec.",
    );
  }
  return url;
}

/** Message headers for <mailbox> (the local-part, e.g. `entetest`), newest first. */
async function headers(mailbox: string): Promise<MessageHeader[]> {
  const res = await fetch(`${baseUrl()}/api/v1/mailbox/${mailbox}`);
  if (!res.ok) throw new Error(`inbucket list ${mailbox}: HTTP ${res.status}`);
  const list = (await res.json()) as MessageHeader[];
  // inbucket returns oldest-first; reverse so callers see the newest mail first.
  return list.reverse();
}

async function message(mailbox: string, id: string): Promise<Message> {
  const res = await fetch(`${baseUrl()}/api/v1/mailbox/${mailbox}/${id}`);
  if (!res.ok) throw new Error(`inbucket get ${mailbox}/${id}: HTTP ${res.status}`);
  return (await res.json()) as Message;
}

/**
 * Poll <mailbox> until a delivered message matches <pattern>, then return the
 * first capture group (or the whole match if the pattern has none). Scans
 * newest-to-oldest so a fresh code wins over a stale one. Throws on timeout.
 *
 * Used for codes a service emails mid-signup — the browser triggers the send
 * (by submitting the email), then the spec awaits the code here and types it
 * back in.
 */
export async function waitForCode(
  mailbox: string,
  pattern: RegExp,
  opts: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<string> {
  const timeoutMs = opts.timeoutMs ?? 60_000;
  const intervalMs = opts.intervalMs ?? 2_000;
  const deadline = Date.now() + timeoutMs;
  let lastErr = "mailbox stayed empty";

  while (Date.now() < deadline) {
    try {
      for (const h of await headers(mailbox)) {
        const msg = await message(mailbox, h.id);
        const haystack = `${msg.subject}\n${msg.body.text}\n${msg.body.html}`;
        const m = haystack.match(pattern);
        if (m) return m[1] ?? m[0];
      }
      lastErr = `no message in ${mailbox} matched ${pattern}`;
    } catch (e) {
      lastErr = String(e);
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(
    `waitForCode(${mailbox}, ${pattern}) timed out after ${timeoutMs}ms: ${lastErr}`,
  );
}
