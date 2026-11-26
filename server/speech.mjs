import {WASI} from 'node:wasi';
import {readFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createRequire} from 'node:module';
import {requireThat} from './db.mjs';
const require=createRequire(import.meta.url);
let engine;
export async function speech(phrase){
  requireThat(typeof phrase==='string'&&phrase.trim()&&phrase.length<=600,'Use a short narration phrase.');
  const dir=await mkdtemp(join(tmpdir(),'goodest-voice-'));
  try{
    engine??=readFile(require.resolve('@echogarden/flite-wasi')).then(data=>WebAssembly.compile(data));
    const wasi=new WASI({version:'preview1',args:['flite','-voice','slt','-t',phrase,'-o','/audio/phrase.wav'],env:{},preopens:{'/audio':dir},returnOnExit:true});
    const instance=await WebAssembly.instantiate(await engine,{wasi_snapshot_preview1:wasi.wasiImport});
    const status=wasi.start(instance);
    requireThat(status===0,'The speech engine could not render audio.',503);
    const data=await readFile(join(dir,'phrase.wav'));requireThat(data.length>44,'Empty speech buffer',503);
    return data;
  }finally{await rm(dir,{recursive:true,force:true});}
}
