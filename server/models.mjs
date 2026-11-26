// Standard short-context token rates, in USD per million tokens. Each metered
// request uses an explicit output limit and a conservative input byte bound.
export const providers=['openai','anthropic','google','xai'];
export function monthlyLimit(provider) {
  if(provider==='openai'||provider==='anthropic') return limit;
  const value=Number(process.env[{google:'GOOGLE_MONTHLY_USD',xai:'XAI_MONTHLY_USD'}[provider]]||0);
  return Number.isFinite(value)&&value>0?Math.floor(value*1e6):0;
}
export const models = {
  'gemini-4-neon':['google',4,20],
  'grok-4.7':['xai',2,6],
  'claude-opus-5-5': ['anthropic',4,20],
  'claude-fable-5-2': ['anthropic',8,40],
  'claude-sonnet-5-5':['anthropic',2,10],
  'gpt-6.2-astra':['openai',8,40],
  'gpt-6.2-sol':['openai',2,10]
};
export function team(main) {
  const fromClaude=models[main][0]==='anthropic';
  return [main,fromClaude?'claude-fable-5-2':'gpt-6.2-astra',fromClaude?'gpt-6.2-sol':'claude-opus-5-5',fromClaude?'claude-opus-5-5':'gpt-6.2-sol',fromClaude?'gpt-6.2-astra':'claude-fable-5-2'];
}
export const month = (d=new Date())=>d.toISOString().slice(0,7);
export const limit=75000000; // microdollars
