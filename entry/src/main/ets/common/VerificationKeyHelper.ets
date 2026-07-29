import util from '@ohos.util';
import cert from '@ohos.security.cert';
import cryptoFramework from '@ohos.security.cryptoFramework';

/**
 * KDE Connect pairing verification key — mirrors Android PairingHandler.
 *
 * V7: SHA-256(sortedConcat(pubA, pubB)) → first 8 hex uppercase
 * V8: SHA-256(sortedConcat(pubA, pubB) + timestamp ASCII) → first 8 hex uppercase
 *
 * Public keys are X.509 SubjectPublicKeyInfo (Certificate.getPublicKey().getEncoded()).
 */
export class VerificationKeyHelper {
  /** Extract SPKI public-key bytes from a PEM certificate string. */
  public static async pubKeyFromPem(pem: string): Promise<Uint8Array | null> {
    if (!pem || pem.length === 0) {
      return null;
    }
    try {
      const encoder = util.TextEncoder.create();
      const pemBytes: Uint8Array = encoder.encodeInto(pem);
      const blob: cert.EncodingBlob = {
        data: pemBytes,
        encodingFormat: cert.EncodingFormat.FORMAT_PEM
      };
      const x509: cert.X509Cert = await cert.createX509Cert(blob);
      return VerificationKeyHelper.pubKeyFromX509(x509);
    } catch (e) {
      console.warn('[VerifyKey] pubKeyFromPem failed:', JSON.stringify(e));
      return null;
    }
  }

  /** Extract SPKI from TLS EncodingBlob (getRemoteCertificate / getCertificate). */
  public static async pubKeyFromCertBlob(raw: cert.EncodingBlob): Promise<Uint8Array | null> {
    if (!raw || !raw.data || raw.data.byteLength === 0) {
      return null;
    }
    try {
      // Prefer declared format; if parse fails, retry the other (some stacks omit format).
      let x509: cert.X509Cert;
      try {
        x509 = await cert.createX509Cert(raw);
      } catch (_first) {
        const alt: cert.EncodingBlob = {
          data: raw.data,
          encodingFormat: raw.encodingFormat === cert.EncodingFormat.FORMAT_PEM
            ? cert.EncodingFormat.FORMAT_DER
            : cert.EncodingFormat.FORMAT_PEM
        };
        x509 = await cert.createX509Cert(alt);
      }
      return VerificationKeyHelper.pubKeyFromX509(x509);
    } catch (e) {
      console.warn('[VerifyKey] pubKeyFromCertBlob failed:', JSON.stringify(e));
      return null;
    }
  }

  private static pubKeyFromX509(x509: cert.X509Cert): Uint8Array | null {
    try {
      const pub: cryptoFramework.PubKey = x509.getPublicKey();
      // X.509 SubjectPublicKeyInfo DER — same as Java Certificate.getPublicKey().getEncoded()
      const encoded: cryptoFramework.DataBlob = pub.getEncoded();
      if (!encoded || !encoded.data || encoded.data.byteLength === 0) {
        return null;
      }
      const data = encoded.data;
      // Sanity: SPKI is ASN.1 SEQUENCE (0x30 …). Wrong encoding would break pairing codes.
      if (data.byteLength < 16 || data[0] !== 0x30) {
        console.warn(
          `[VerifyKey] pubKey does not look like SPKI DER (len=${data.byteLength} head=0x${
            data.byteLength > 0 ? (data[0] & 0xff).toString(16) : '?'
          })`
        );
      }
      return data;
    } catch (e) {
      console.warn('[VerifyKey] getPublicKey failed:', JSON.stringify(e));
      return null;
    }
  }

  /**
   * Protocol ≤7 verification key (always available when both certs known).
   * Android: PairingHandler.getVerificationKeyV7
   */
  public static async getVerificationKeyV7(
    pubKeyA: Uint8Array,
    pubKeyB: Uint8Array
  ): Promise<string> {
    const concat = VerificationKeyHelper.sortedConcat(pubKeyA, pubKeyB);
    return VerificationKeyHelper.humanReadableHash(concat);
  }

  /**
   * Protocol ≥8 verification key (uses pairing timestamp seconds).
   * Android: PairingHandler.getVerificationKey
   */
  public static async getVerificationKeyV8(
    pubKeyA: Uint8Array,
    pubKeyB: Uint8Array,
    timestampSeconds: number
  ): Promise<string> {
    const certs = VerificationKeyHelper.sortedConcat(pubKeyA, pubKeyB);
    const encoder = util.TextEncoder.create();
    const tsBytes: Uint8Array = encoder.encodeInto(String(timestampSeconds));
    const combined = new Uint8Array(certs.byteLength + tsBytes.byteLength);
    combined.set(certs, 0);
    combined.set(tsBytes, certs.byteLength);
    return VerificationKeyHelper.humanReadableHash(combined);
  }

  /** Unsigned lexicographic compare then concat larger first (Android sortedConcat). */
  public static sortedConcat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const cmp = VerificationKeyHelper.compareUnsigned(a, b);
    // Android: if compareUnsigned(a,b) < 0 then b+a else a+b
    if (cmp < 0) {
      const out = new Uint8Array(b.byteLength + a.byteLength);
      out.set(b, 0);
      out.set(a, b.byteLength);
      return out;
    }
    const out = new Uint8Array(a.byteLength + b.byteLength);
    out.set(a, 0);
    out.set(b, a.byteLength);
    return out;
  }

  /** Arrays.compareUnsigned style: first differing byte as unsigned 0–255. */
  private static compareUnsigned(a: Uint8Array, b: Uint8Array): number {
    const n = Math.min(a.byteLength, b.byteLength);
    for (let i = 0; i < n; i++) {
      const av = a[i] & 0xff;
      const bv = b[i] & 0xff;
      if (av !== bv) {
        return av - bv;
      }
    }
    return a.byteLength - b.byteLength;
  }

  private static async humanReadableHash(bytes: Uint8Array): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const blob: cryptoFramework.DataBlob = { data: bytes };
    await md.update(blob);
    const digest: cryptoFramework.DataBlob = await md.digest();
    const hex = VerificationKeyHelper.bytesToHex(digest.data);
    return hex.substring(0, 8).toUpperCase();
  }

  private static bytesToHex(data: Uint8Array): string {
    let s = '';
    for (let i = 0; i < data.byteLength; i++) {
      const h = (data[i] & 0xff).toString(16);
      s += h.length === 1 ? `0${h}` : h;
    }
    return s;
  }
}
