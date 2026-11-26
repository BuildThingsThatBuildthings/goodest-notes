export async function readText(request, maximum) {
  const tooLarge = () => Object.assign(new Error('Payload too large'), {status:413});
  if (Number(request.headers.get('content-length')) > maximum) throw tooLarge();
  if (!request.body) return '';
  const reader = request.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    for (;;) {
      const {done,value} = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maximum) {
        void reader.cancel().catch(() => {});
        throw tooLarge();
      }
      chunks.push(value);
    }
    return Buffer.concat(chunks,length).toString('utf8');
  } finally { reader.releaseLock(); }
}
