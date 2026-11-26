import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
const [file]=process.argv.slice(2);
if(!file||!process.env.PUBLIC_URL||!process.env.OWNER_TOKEN)throw Error('Provide a local catalog JSON file and configure PUBLIC_URL and OWNER_TOKEN.');
const input=JSON.parse(await readFile(file,'utf8'));
const rows=Array.isArray(input)?input:input.projects;
if(!Array.isArray(rows))throw Error('Expected a projects array.');
function stableID(id){
  const bytes=createHash('sha256').update('goodest-notes:ryan-ops:project:'+id).digest().subarray(0,16);
  bytes[6]=(bytes[6]&15)|128;bytes[8]=(bytes[8]&63)|128;
  const hex=bytes.toString('hex');return [hex.slice(0,8),hex.slice(8,12),hex.slice(12,16),hex.slice(16,20),hex.slice(20)].join('-');
}
const projects=rows.map(row=>{
  const externalID=row.projectSlug??row.slug??row.id,title=row.title??row.name;
  if(typeof externalID!=='string'||!externalID.trim()||typeof title!=='string'||!title.trim())throw Error('Each project needs a stable ID or slug and a title.');
  return {id:stableID(externalID),externalID,title};
});
const response=await fetch(new URL('/v1/catalog',process.env.PUBLIC_URL),{method:'POST',headers:{Authorization:'Bearer '+process.env.OWNER_TOKEN,'Content-Type':'application/json'},body:JSON.stringify({projects})});
if(!response.ok)throw Error('Catalog import failed: '+response.status);
console.log('Imported '+(await response.json()).count+' project references.');
