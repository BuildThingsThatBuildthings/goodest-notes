import {handle} from '../../server/api.mjs';
export default handle;
export const config={path:['/health','/mcp','/authorize','/token','/revoke','/register','/.well-known/*','/v1/*']};
