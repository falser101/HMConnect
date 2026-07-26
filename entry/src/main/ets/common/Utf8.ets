import util from '@ohos.util';

/** Decode UTF-8 bytes without deprecated decodeWithStream. */
export function utf8Decode(bytes: Uint8Array): string {
  let decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes);
}
