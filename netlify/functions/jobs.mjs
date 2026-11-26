import {tick} from '../../server/worker.mjs';
export default async()=>{await tick();return new Response(null,{status:204});};
export const config={schedule:'* * * * *'};
