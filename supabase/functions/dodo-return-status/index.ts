import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SITE_ORIGIN="https://ozdalmete-netizen.github.io";
const MAX_BODY_BYTES=4096;
const cors={"Access-Control-Allow-Origin":SITE_ORIGIN,"Access-Control-Allow-Headers":"content-type","Access-Control-Allow-Methods":"POST,OPTIONS","Vary":"Origin"};
const json=(d:unknown,s=200)=>new Response(JSON.stringify(d),{status:s,headers:{...cors,"Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store","X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer"}});
const uuidRe=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const tokenRe=/^[a-f0-9]{64}$/i;
async function sha256Hex(v:string){const b=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v));return [...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,"0")).join("")}
async function boundedJson(req:Request,maxBytes:number){
  const declared=Number(req.headers.get("content-length")||0);
  if(Number.isFinite(declared)&&declared>maxBytes)throw Object.assign(new Error("REQUEST_TOO_LARGE"),{status:413,code:"REQUEST_TOO_LARGE"});
  const reader=req.body?.getReader();if(!reader)return {};
  const chunks:Uint8Array[]=[];let total=0;
  while(true){const {done,value}=await reader.read();if(done)break;if(value){total+=value.byteLength;if(total>maxBytes){try{await reader.cancel()}catch{};throw Object.assign(new Error("REQUEST_TOO_LARGE"),{status:413,code:"REQUEST_TOO_LARGE"});}chunks.push(value)}}
  const all=new Uint8Array(total);let o=0;for(const c of chunks){all.set(c,o);o+=c.length}
  if(!total)return {};
  try{return JSON.parse(new TextDecoder().decode(all))}catch{throw Object.assign(new Error("INVALID_JSON"),{status:400,code:"INVALID_JSON"})}
}

Deno.serve(async req=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
  if(req.method!=="POST")return json({ok:false,code:"METHOD_NOT_ALLOWED"},405);
  const origin=req.headers.get("origin");
  if(origin&&origin!==SITE_ORIGIN)return json({ok:false,code:"ORIGIN_NOT_ALLOWED"},403);

  try{
    const body=await boundedJson(req,MAX_BODY_BYTES);
    const paymentRowId=String(body?.payment_row_id||"").trim();
    const returnToken=String(body?.return_token||"").trim();
    if(!paymentRowId||!returnToken)return json({ok:false,code:"INVALID_REQUEST"},400);
    if(!uuidRe.test(paymentRowId))return json({ok:false,code:"INVALID_PAYMENT_ROW_ID"},400);
    if(!tokenRe.test(returnToken))return json({ok:false,code:"INVALID_RETURN_CAPABILITY"},400);

    const tokenHash=await sha256Hex(returnToken);
    const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false,autoRefreshToken:false}});

    const {data:payment,error:paymentErr}=await db.from("payments")
      .select("id,batch_id,status,provider_status,environment,return_token_hash,return_token_expires_at")
      .eq("provider","dodo").eq("environment","live_mode").eq("id",paymentRowId).maybeSingle();
    if(paymentErr)throw paymentErr;
    if(!payment)return json({ok:false,code:"NOT_FOUND"},404);
    if(!payment.return_token_hash||String(payment.return_token_hash)!==tokenHash)return json({ok:false,code:"NOT_FOUND"},404);
    const capabilityExpiry=payment.return_token_expires_at?Date.parse(String(payment.return_token_expires_at)):NaN;
    if(!Number.isFinite(capabilityExpiry)||capabilityExpiry<Date.now())return json({ok:false,code:"RETURN_CAPABILITY_EXPIRED"},410);

    const {data:batch,error:batchErr}=await db.from("checkout_batches")
      .select("id,canvas,item_count,status").eq("id",payment.batch_id).maybeSingle();
    if(batchErr)throw batchErr;
    if(!batch)return json({ok:false,code:"BATCH_NOT_FOUND"},404);

    const {count:sealedCount,error:countErr}=await db.from("marks").select("mark_number",{count:"exact",head:true}).eq("batch_id",batch.id);
    if(countErr)throw countErr;
    const sealed=Number(sealedCount||0);const expected=Number(batch.item_count||0);
    const providerStatus=String(payment.provider_status||"").toLowerCase();
    const verified=batch.status==="paid"&&payment.status==="paid"&&providerStatus==="succeeded"&&expected>0&&sealed===expected;

    let marks:any[]=[];
    if(verified){
      const {data,error}=await db.from("marks")
        .select("mark_number,canvas,x,y,color_id,country_code,ai_provider,ai_model,sealed_at,certificate_id,share_slug")
        .eq("batch_id",batch.id).order("mark_number",{ascending:true});
      if(error)throw error;marks=data||[];
      if(marks.length!==expected)return json({ok:false,code:"SEALED_COUNT_MISMATCH"},409);
    }

    return json({
      ok:true,verified,
      batch_status:batch.status,payment_status:payment.status,provider_status:payment.provider_status,
      sealed_marks:sealed,expected_marks:expected,
      batch:{id:batch.id,canvas:batch.canvas,item_count:expected,status:batch.status},
      marks
    });
  }catch(e:any){
    const code=String(e?.code||"");const status=Number(e?.status)||500;
    if(code==="REQUEST_TOO_LARGE"||code==="INVALID_JSON")return json({ok:false,code},status);
    console.error("dodo-return-status",e);
    return json({ok:false,code:"INTERNAL_ERROR"},500);
  }
});
