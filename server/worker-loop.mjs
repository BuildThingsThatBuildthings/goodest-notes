import {tick} from './worker.mjs';
import {setTimeout} from 'node:timers/promises';
for(;;){try{if(await tick()) continue;}catch{console.error('Workspace worker unavailable');}await setTimeout(5000);}
