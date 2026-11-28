import test from 'node:test';
import assert from 'node:assert/strict';
import {readText} from './request.mjs';

test('body limit counts streamed bytes and accepts the exact boundary',async()=>{
  const request=()=>new Request('https://notes.example/register',{method:'POST',body:'éé'});
  assert.equal(await readText(request(),4),'éé');
  await assert.rejects(readText(request(),3),{status:413});
});
