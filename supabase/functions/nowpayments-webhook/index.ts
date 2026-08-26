import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MAX_BODY_BYTES=256*1024;
const json=(d:unknown,s=200)=>new Response(JSON.stringify(d),{status:s,headers:{"Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"}});
function sortObject(value:any):any{if(Array.isArray(value))return value.map(sortObject);if(value&&typeof value==='object')return Object.keys(value).sort().reduce((o:any,k)=>{o[k]=sortObject(value[k]);return o},{});return value}
function bytesToHex(bytes:ArrayBuffer){return [...new Uint8Array(bytes)].map(b=>b.toString(16).padStart(2,'0')).join('')}
async function hmacSha512Hex(secret:string,message:string){const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-512'},false,['sign']);return bytesToHex(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(message)))}
async function sha256Hex(v:string){return bytesToHex(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(v)))}
async function readRawBounded(req:Request,maxBytes:number){const declared=Number(req.headers.get('content-length')||0);if(Number.isFinite(declared)&&declared>maxBytes)throw Object.assign(new Error('REQUEST_TOO_LARGE'),{code:'REQUEST_TOO_LARGE'});const reader=req.body?.getReader();if(!reader)return '';const chunks:Uint8Array[]=[];let total=0;while(true){const {done,value}=await reader.read();if(done)break;if(value){total+=value.byteLength;if(total>maxBytes){try{await reader.cancel()}catch{};throw Object.assign(new Error('REQUEST_TOO_LARGE'),{code:'REQUEST_TOO_LARGE'})}chunks.push(value)}}const all=new Uint8Array(total);let o=0;for(const c of chunks){all.set(c,o);o+=c.length}return new TextDecoder().decode(all)}

Deno.serve(async req=>{
  if(req.method!=='POST')return json({ok:false,code:'METHOD_NOT_ALLOWED'},405);
  try{
    const ipnSecret=Deno.env.get('NOWPAYMENTS_IPN_SECRET');const apiKey=Deno.env.get('NOWPAYMENTS_API_KEY');if(!ipnSecret||!apiKey)return json({ok:false,code:'NOWPAYMENTS_NOT_CONFIGURED'},503);
    const raw=await readRawBounded(req,MAX_BODY_BYTES);let body:any;try{body=JSON.parse(raw)}catch{return json({ok:false,code:'INVALID_JSON'},400)}
    const received=(req.headers.get('x-nowpayments-sig')||'').toLowerCase();const canonical=JSON.stringify(sortObject(body));const expected=(await hmacSha512Hex(ipnSecret,canonical)).toLowerCase();if(!received||received!==expected)return json({ok:false,code:'BAD_SIGNATURE'},401);
    const paymentId=String(body?.payment_id||'');if(!paymentId)return json({ok:false,code:'MISSING_PAYMENT_ID'},400);
    const verifyResp=await fetch(`https://api.nowpayments.io/v1/payment/${encodeURIComponent(paymentId)}`,{headers:{'x-api-key':apiKey}});const provider=await verifyResp.json();if(!verifyResp.ok)return json({ok:false,code:'PROVIDER_RECHECK_FAILED'},502);
    if(String(provider.payment_id)!==paymentId)return json({ok:false,code:'PAYMENT_ID_MISMATCH'},400);if(String(provider.order_id||'')!==String(body.order_id||''))return json({ok:false,code:'ORDER_MISMATCH'},400);
    const normalized={...body,...provider,payment_id:provider.payment_id,order_id:provider.order_id,payment_status:provider.payment_status,price_amount:provider.price_amount,price_currency:provider.price_currency,pay_currency:provider.pay_currency,pay_amount:provider.pay_amount,actually_paid:provider.actually_paid};
    const eventId=await sha256Hex(`${paymentId}|${String(provider.payment_status||'')}|${canonical}`);
    const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data,error}=await db.rpc('process_nowpayments_payment_atomic',{p_event_id:eventId,p_provider_payment_id:paymentId,p_order_id:String(provider.order_id||''),p_provider_status:String(provider.payment_status||''),p_price_amount:Number(provider.price_amount),p_price_currency:String(provider.price_currency||''),p_pay_currency:String(provider.pay_currency||''),p_pay_amount:provider.pay_amount==null?null:Number(provider.pay_amount),p_actually_paid:provider.actually_paid==null?null:Number(provider.actually_paid),p_raw:normalized});
    if(error)throw error;if(!data?.ok)return json(data,409);
    const {error:processedErr}=await db.from('webhook_events').update({processed_at:new Date().toISOString()}).eq('provider','nowpayments').eq('provider_event_id',eventId).is('processed_at',null);if(processedErr)console.warn('webhook processed marker',processedErr.message);
    return json(data,200);
  }catch(e:any){if(e?.code==='REQUEST_TOO_LARGE')return json({ok:false,code:'REQUEST_TOO_LARGE'},413);console.error(e);return json({ok:false,code:'INTERNAL_ERROR'},500)}
});
