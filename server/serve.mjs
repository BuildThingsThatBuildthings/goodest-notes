import http from 'node:http';
import {Readable} from 'node:stream';
import {readFile} from 'node:fs/promises';
import {handle} from './api.mjs';
import {migrate} from './db.mjs';
await migrate();
http.createServer(async(incoming,out)=>{
  try{
    if(incoming.url==='/'){out.setHeader('Content-Type','text/html');out.end(await readFile(new URL('../public/index.html',import.meta.url)));return;}
    const init={method:incoming.method,headers:incoming.headers};
    if(!['GET','HEAD'].includes(incoming.method)){init.body=Readable.toWeb(incoming);init.duplex='half';}
    const response=await handle(new Request(new URL(incoming.url,'http://localhost'),init));
    out.writeHead(response.status,Object.fromEntries(response.headers));out.end(Buffer.from(await response.arrayBuffer()));
  }catch{out.writeHead(500);out.end();}
}).listen(Number(process.env.PORT||8080),'0.0.0.0');
