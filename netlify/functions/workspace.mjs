import {handle} from '../../server/api.mjs';
export default handle;
export const config={path:['/health','/mcp','/authorize','/token','/.well-known/*','/v1/*']};
