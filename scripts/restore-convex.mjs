import {readFile,readdir} from 'node:fs/promises';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {database,migrate,transaction,one} from '../server/db.mjs';
import {digest} from '../server/auth.mjs';
import {canonicalJSON} from '../server/json.mjs';

const folder=process.argv[2];
if(!folder||!process.env.DATABASE_URL)throw Error('Specify an extracted Convex backup and DATABASE_URL for an empty PostgreSQL database.');
const data=(await readFile(join(folder,'entries/documents.jsonl'),'utf8')).split('\n').filter(Boolean).map(x=>JSON.parse(x));
const rows=name=>data.filter(r=>r.collection===name);
const json=x=>JSON.stringify(x);
const date=value=>new Date(value);
await migrate();
await transaction(async c=>{
  const counts=await one(c,'SELECT (SELECT count(*) FROM projects)+(SELECT count(*) FROM records)+(SELECT count(*) FROM spend)+(SELECT count(*) FROM grants)+(SELECT count(*) FROM chunks) total');
  if(Number(counts.total)!==0)throw Error('Restore requires an empty database.');
  for(const {value:p} of rows('project'))await c.query('INSERT INTO projects(id,title,rules,catalog_id) VALUES($1,$2,$3,$4)',[p.id,p.title,p.rules,p.catalog_id]);
  for(const {value:r} of rows('record'))await c.query('INSERT INTO records(id,kind,body,rev) VALUES($1,$2,$3,$4)',[r.id,r.kind,json(r.body),r.rev]);
  for(const {scope,value} of rows('member'))await c.query('INSERT INTO members VALUES($1,$2)',[scope,value.id]);
  for(const {value:r} of rows('conflict'))await c.query('INSERT INTO conflicts VALUES($1,$2,$3,$4,$5,$6,$7)',[r.id,r.project,r.record,r.actor,json(r.proposed),r.base,r.created]);
  for(const {value:t} of rows('task'))await c.query('INSERT INTO tasks(id,project,brief,anchor,state,stage,models,history,created,target,base) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)',[t.id,t.project,t.brief,t.anchor,t.lease?'paused':t.state,t.stage,json(t.models),json(t.history),date(t.created),t.target,t.base]);
  for(const {value:m} of rows('message').sort((a,b)=>a.value.seq-b.value.seq))await c.query('INSERT INTO messages(id,project,author,body,anchor,reply,task,created) VALUES($1,$2,$3,$4,$5,$6,$7,$8)',[m.id,m.project,m.author,m.body,m.anchor,m.reply,m.task,m.created]);
  for(const {value:g} of rows('grant'))await c.query('INSERT INTO grants VALUES($1,$2,$3,$4,$5,$6,$7,$8)',[g.id,g.access,g.refresh||digest('unused-'+g.id),g.client,g.project,date(g.expires),date(g.refreshExpires||0),g.revoked]);
  for(const {value:r} of rows('reservation'))await c.query('INSERT INTO spend(id,month,provider,reserved,charged) VALUES($1,$2,$3,$4,$5)',[r.id,r.period,r.provider,r.reserved,r.charged]);
  for(const {key,value} of rows('chunk')){
    const bytes=Buffer.from(value,'base64');if(createHash('sha256').update(bytes).digest('hex')!==key)throw Error('A media chunk failed checksum verification.');
    await c.query('INSERT INTO chunks VALUES($1,$2)',[key,bytes]);
  }
  for(const {value:r} of rows('record').filter(x=>x.value.kind==='asset'))for(const hash of r.body.chunks){if(!await one(c,'SELECT 1 FROM chunks WHERE hash=$1',[hash]))throw Error('An attachment is missing a chunk.');}
  for(const {key,value:r} of rows('visual')){
    let result=r.result||null;
    if(result?.storage){const filename=(await readdir(join(folder,'_storage'))).find(f=>f===result.storage||f.startsWith(result.storage+'.'));if(!filename)throw Error('Cached media file missing');result={format:result.format,data:(await readFile(join(folder,'_storage',filename))).toString('base64')};}
    await c.query('INSERT INTO visuals VALUES($1,$2,$3,$4)',[key,r.signature,r.reservation,result?json(result):null]);
  }
  for(const {key,value:r} of rows('receipt')){const [actor,p,id]=key.split('/');await c.query('INSERT INTO receipts VALUES($1,$2,$3,$4,$5)',[actor,p,id,digest(canonicalJSON(r.args)),json(r.result)]);}
  const main=rows('setting').find(r=>r.key==='main')?.value;
  if(main)await c.query('UPDATE settings SET main=$1 WHERE id=1',[main]);
});
await (await database()).end();
console.log('Restored '+rows('project').length+' projects, '+rows('record').length+' records, '+rows('message').length+' messages and '+rows('chunk').length+' verified chunks.');
