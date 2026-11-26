// Standard short-context token rates, in USD per million tokens. Each metered
// request uses an explicit output limit and a conservative input byte bound.
export const models = {
  'claude-opus-5-5': ['anthropic',4,20],
  'claude-fable-5-2': ['anthropic',8,40],
  'claude-sonnet-5-5':['anthropic',2,10],
  'gpt-6.2-astra':['openai',8,40],
  'gpt-6.2-sol':['openai',2,10]
};
export function team(main) {
  const fromClaude=models[main][0]==='anthropic';
  return [main,fromClaude?'gpt-6.2-sol':'claude-opus-5-5',fromClaude?'claude-opus-5-5':'gpt-6.2-sol',fromClaude?'gpt-6.2-astra':'claude-fable-5-2'];
}
export const month = (d=new Date())=>d.toISOString().slice(0,7);
export const limit=75000000; // microdollars
