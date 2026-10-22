// Bearer-token check in constant time.

const encoder = new TextEncoder();

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

/**
 * True when the request carries `Authorization: Bearer <secret>`. Both sides are
 * hashed first, so the comparison runs over two 32-byte digests whatever the
 * length of the guess. An unset or empty secret never matches.
 */
export async function bearerMatches(request: Request, secret: string | undefined): Promise<boolean> {
  const header = request.headers.get("authorization") ?? "";
  const m = /^Bearer (.+)$/i.exec(header);
  const [given, wanted] = await Promise.all([digest(m?.[1] ?? ""), digest(secret ?? "")]);
  let diff = 0;
  for (let i = 0; i < given.length; i++) diff |= given[i]! ^ wanted[i]!;
  return diff === 0 && m !== null && !!secret;
}
