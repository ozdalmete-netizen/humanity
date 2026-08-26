import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Webhook } from "npm:standardwebhooks";

const MAX_BODY_BYTES=512*1024;
const LIVE_BASE="https://live.dodopayments.com";
const json=(d:unknown,s=200)=>new Response(JSON.stringify(d),{status:s,headers:{"Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store","X-Content-Type-Options":"nosniff"}});
const uuidRe=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const currencyRe=/^[A-Z]{3}$/;
const safe=(v:unknown)=>String(v??"").replace(/[\r\n]+/g," ").slice(0,240);
const reversalTypes=new Set(["refund.succeeded","refund.failed","dispute.opened","dispute.expired","dispute.accepted","dispute.cancelled","dispute.challenged","dispute.won","dispute.lost"]);
async function dodoGet(path:string,key:string){const r=await fetch(`${LIVE_BASE}${path}`,{headers:{Authorization:`Bearer ${key}`}});const t=await r.text();let b:any=t;try{b=JSON.parse(t)}catch{}return {ok:r.ok,status:r.status,body:b,text:t}}
async function readRawBounded(req:Request,maxBytes:number){const declared=Number(req.headers.get("content-length")||0);if(Number.isFinite(declared)&&declared>maxBytes)throw Object.assign(new Error("REQUEST_TOO_LARGE"),{code:"REQUEST_TOO_LARGE"});const reader=req.body?.getReader();if(!reader)return "";const chunks:Uint8Array[]=[];let total=0;while(true){const {done,value}=await reader.read();if(done)break;if(value){total+=value.byteLength;if(total>maxBytes){try{await reader.cancel()}catch{};throw Object.assign(new Error("REQUEST_TOO_LARGE"),{code:"REQUEST_TOO_LARGE"})}chunks.push(value)}}const all=new Uint8Array(total);let o=0;for(const c of chunks){all.set(c,o);o+=c.length}return new TextDecoder().decode(all)}

Deno.serve(async req=>{
  if(req.method!=="POST")return json({ok:false,code:"METHOD_NOT_ALLOWED"},405);
  try{
    const apiKey=Deno.env.get("DODO_LIVE_API_KEY"),webhookKey=Deno.env.get("DODO_LIVE_WEBHOOK_KEY"),productId=Deno.env.get("DODO_LIVE_PRODUCT_ID");
    if(!apiKey||!webhookKey||!productId)return json({ok:false,code:"DODO_LIVE_NOT_CONFIGURED"},503);
    const raw=await readRawBounded(req,MAX_BODY_BYTES);
    const headers={"webhook-id":req.headers.get("webhook-id")||"","webhook-signature":req.headers.get("webhook-signature")||"","webhook-timestamp":req.headers.get("webhook-timestamp")||""};
    if(!headers["webhook-id"]||!headers["webhook-signature"]||!headers["webhook-timestamp"])return json({ok:false,code:"MISSING_SIGNATURE_HEADERS"},401);
    try{await new Webhook(webhookKey).verify(raw,headers)}catch(e){console.error("Dodo LIVE signature verify failed",e);return json({ok:false,code:"BAD_SIGNATURE"},401)}
    let body:any;try{body=JSON.parse(raw)}catch{return json({ok:false,code:"INVALID_JSON"},400)}
    const type=String(body?.type||""),data=body?.data||{};
    const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false,autoRefreshToken:false}});

    if(reversalTypes.has(type)){
      const providerPaymentId=String(data?.payment_id||"").trim();if(!providerPaymentId)return json({ok:false,code:"MISSING_PAYMENT_ID"},400);
      const pay=await dodoGet(`/payments/${encodeURIComponent(providerPaymentId)}`,apiKey);if(!pay.ok)return json({ok:false,code:"DODO_LIVE_PAYMENT_RECHECK_FAILED",provider_http:pay.status},502);
      const payment=pay.body;if(String(payment?.payment_id||"")!==providerPaymentId)return json({ok:false,code:"PAYMENT_ID_MISMATCH"},409);
      const meta=payment?.metadata||{};if(String(meta?.h1_environment||"")!=="live_mode")return json({ok:true,action:"IGNORED_NON_H1_FINANCIAL_EVENT"},200);
      const paymentRowId=String(meta?.h1_payment_row_id||""),batchId=String(meta?.h1_batch_id||""),orderId=String(meta?.h1_order_id||"");
      if(!uuidRe.test(paymentRowId)||!uuidRe.test(batchId)||!orderId)return json({ok:false,code:"MISSING_H1_METADATA"},409);
      const cart=Array.isArray(payment?.product_cart)?payment.product_cart:[];if(cart.length!==1||String(cart[0]?.product_id||"")!==productId)return json({ok:false,code:"PRODUCT_MISMATCH"},409);
      const {data:row,error:rowErr}=await db.from("payments").select("id,batch_id,provider_order_id,provider_payment_id,provider_payload,environment").eq("id",paymentRowId).eq("provider","dodo").eq("environment","live_mode").maybeSingle();if(rowErr)throw rowErr;
      if(!row||String(row.batch_id)!==batchId||String(row.provider_order_id)!==orderId)return json({ok:false,code:"H1_METADATA_MISMATCH"},409);
      if(String(row?.provider_payload?.environment||"")!=="live_mode")return json({ok:false,code:"STORED_ENVIRONMENT_MISMATCH"},409);
      if(String(row?.provider_payload?.h1_product_id||"")!==productId)return json({ok:false,code:"STORED_PRODUCT_MISMATCH"},409);
      if(row.provider_payment_id&&String(row.provider_payment_id)!==providerPaymentId)return json({ok:false,code:"PROVIDER_PAYMENT_MISMATCH"},409);
      const providerEventId=`live:${headers["webhook-id"]}`;const resourceId=type.startsWith("refund.")?String(data?.refund_id||"").slice(0,160):String(data?.dispute_id||"").slice(0,160);const amountText=data?.amount==null?null:String(data.amount).slice(0,80);const currencyRaw=String(data?.currency||"").toUpperCase();const currency=currencyRe.test(currencyRaw)?currencyRaw:null;const occurredAt=String(body?.timestamp||data?.created_at||"");const occurredAtSafe=occurredAt&&!Number.isNaN(Date.parse(occurredAt))?new Date(occurredAt).toISOString():null;
      const {error:insertErr}=await db.from("payment_reversal_events").insert({provider:"dodo",provider_event_id:providerEventId,payment_id:row.id,provider_payment_id:providerPaymentId,event_type:type,resource_id:resourceId||null,amount_text:amountText,currency,is_partial:typeof data?.is_partial==="boolean"?data.is_partial:null,occurred_at:occurredAtSafe});
      if(insertErr){if(String(insertErr.code)==="23505")return json({ok:true,action:"DUPLICATE_FINANCIAL_EVENT"},200);throw insertErr}return json({ok:true,action:"FINANCIAL_EVENT_RECORDED",type},200);
    }

    if(!type.startsWith("payment."))return json({ok:true,action:"IGNORED_EVENT"},200);
    const webhookPaymentId=String(data?.payment_id||"");if(!webhookPaymentId)return json({ok:false,code:"MISSING_PAYMENT_ID"},400);
    const pay=await dodoGet(`/payments/${encodeURIComponent(webhookPaymentId)}`,apiKey);if(!pay.ok)return json({ok:false,code:"DODO_LIVE_PAYMENT_RECHECK_FAILED",provider_http:pay.status},502);
    const payment=pay.body;if(String(payment?.payment_id||"")!==webhookPaymentId)return json({ok:false,code:"PAYMENT_ID_MISMATCH"},409);
    const meta=payment?.metadata||{};if(String(meta?.h1_environment||"")!=="live_mode")return json({ok:true,action:"IGNORED_NON_H1_LIVE_PAYMENT"},200);
    const paymentRowId=String(meta?.h1_payment_row_id||""),batchId=String(meta?.h1_batch_id||""),orderId=String(meta?.h1_order_id||"");if(!uuidRe.test(paymentRowId)||!uuidRe.test(batchId)||!orderId)return json({ok:false,code:"MISSING_H1_METADATA"},409);
    const cart=Array.isArray(payment?.product_cart)?payment.product_cart:[];if(cart.length!==1||String(cart[0]?.product_id||"")!==productId)return json({ok:false,code:"PRODUCT_MISMATCH"},409);const quantity=Number(cart[0]?.quantity);if(!Number.isInteger(quantity)||quantity<1||quantity>1000)return json({ok:false,code:"INVALID_QUANTITY"},409);if(Number(meta?.h1_item_count)!==quantity)return json({ok:false,code:"METADATA_QUANTITY_MISMATCH"},409);
    const prod=await dodoGet(`/products/${encodeURIComponent(productId)}`,apiKey);const price=prod.body?.price||{};const productOk=prod.ok&&String(prod.body?.product_id||"")===productId&&String(price?.type||"")==="one_time_price"&&String(price?.currency||"").toUpperCase()==="USD"&&Number(price?.price)===499&&price?.tax_inclusive!==true;if(!productOk)return json({ok:false,code:"DODO_LIVE_PRODUCT_MISCONFIGURED"},409);
    const normalized={environment:"live_mode",h1_product_id:productId,webhook:body,payment};
    const {data:row,error:rowErr}=await db.from("payments").select("id,batch_id,provider_order_id,provider_payload,environment").eq("id",paymentRowId).eq("provider","dodo").eq("environment","live_mode").maybeSingle();if(rowErr)throw rowErr;if(!row||String(row.batch_id)!==batchId||String(row.provider_order_id)!==orderId)return json({ok:false,code:"H1_METADATA_MISMATCH"},409);if(String(row?.provider_payload?.environment||"")!=="live_mode")return json({ok:false,code:"STORED_ENVIRONMENT_MISMATCH"},409);if(String(row?.provider_payload?.h1_product_id||"")!==productId)return json({ok:false,code:"STORED_PRODUCT_MISMATCH"},409);
    const storedSession=String(row?.provider_payload?.session_id||""),returnedSession=String(payment?.checkout_session_id||"");if(storedSession&&returnedSession&&storedSession!==returnedSession)return json({ok:false,code:"CHECKOUT_SESSION_MISMATCH"},409);

    const providerStatus=String(payment?.status||"").toLowerCase();
    if(providerStatus==="succeeded"){
      const discounts=Array.isArray(payment?.discounts)?payment.discounts:[];if(discounts.length>0||payment?.discount_id)return json({ok:false,code:"DISCOUNT_NOT_ALLOWED"},409);
      const chargeCurrency=String(payment?.currency||"").toUpperCase();const totalAmount=Number(payment?.total_amount);
      if(!currencyRe.test(chargeCurrency)||!Number.isInteger(totalAmount)||totalAmount<=0)return json({ok:false,code:"CHARGE_EVIDENCE_INVALID"},409);
      const expectedBase=quantity*499;if(chargeCurrency==="USD"&&totalAmount<expectedBase)return json({ok:false,code:"UNDERPAYMENT_BLOCKED"},409);
      const settlementCurrency=String(payment?.settlement_currency||"").toUpperCase();const settlementAmount=Number(payment?.settlement_amount);
      if(!currencyRe.test(settlementCurrency)||!Number.isInteger(settlementAmount)||settlementAmount<=0)return json({ok:false,code:"SETTLEMENT_EVIDENCE_INVALID"},409);
    }

    const eventId=`live:${headers["webhook-id"]}`;const {data:result,error}=await db.rpc("process_dodo_payment_atomic",{p_event_id:eventId,p_payment_row_id:paymentRowId,p_provider_payment_id:webhookPaymentId,p_checkout_session_id:payment?.checkout_session_id?String(payment.checkout_session_id):null,p_provider_status:String(payment?.status||""),p_quantity:quantity,p_raw:normalized});if(error)throw error;if(!result?.ok)return json(result,409);const {error:markErr}=await db.from("webhook_events").update({processed_at:new Date().toISOString()}).eq("provider","dodo").eq("provider_event_id",eventId).is("processed_at",null);if(markErr)throw markErr;return json(result,200);
  }catch(e:any){if(e?.code==="REQUEST_TOO_LARGE")return json({ok:false,code:"REQUEST_TOO_LARGE"},413);console.error("dodo-live-webhook",safe(e instanceof Error?e.message:e));return json({ok:false,code:"INTERNAL_ERROR"},500)}
});
