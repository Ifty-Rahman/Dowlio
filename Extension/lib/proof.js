const encoder = new TextEncoder();

export function base64Url(bytes) {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function nonce() {
  return base64Url(crypto.getRandomValues(new Uint8Array(24)));
}

async function secretOf(token) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(token)));
}

async function code(token, text) {
  const key = await crypto.subtle.importKey("raw", await secretOf(token), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return base64Url(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(text))));
}

export function keyOf(token) {
  return code(token, "dowlio-connect key");
}

export function serverProof(token, client, server) {
  return code(token, `dowlio-connect server ${client} ${server}`);
}

export function clientProof(token, client, server) {
  return code(token, `dowlio-connect client ${client} ${server}`);
}

export function sameText(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  return difference === 0;
}
