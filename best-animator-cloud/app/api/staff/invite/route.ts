import {NextRequest, NextResponse} from 'next/server';
import {createClient} from '@supabase/supabase-js';

// The administrative invite runs inside the owner's Supabase project.
// Vercel needs only the public URL and anon key; no service-role key is used here.
const allowedOrigins = new Set([
 'https://best-animator-cloud-git-feature-owner-manager-f7bf33-s914307771.vercel.app',
 'https://best-animator-cloud.vercel.app',
]);

export async function POST(request:NextRequest) {
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
 const anon=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY?.trim();
 const redirectTo=process.env.CRM_PUBLIC_URL?.trim();
 if(!url||!anon||!redirectTo)
  return NextResponse.json({error:'STAFF_INVITE_NOT_CONFIGURED'}, {status:503});

 let redirect:URL;
 try{redirect=new URL(redirectTo)}
 catch{return NextResponse.json({error:'INVALID_CRM_PUBLIC_URL'}, {status:503})}
 if(!allowedOrigins.has(redirect.origin)||redirect.pathname!=='/'||
    redirect.username||redirect.password||redirect.search||redirect.hash)
  return NextResponse.json({error:'INVALID_CRM_PUBLIC_URL'}, {status:503});

 const bearer=request.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];
 if(!bearer)return NextResponse.json({error:'UNAUTHORIZED'}, {status:401});
 const userClient=createClient(url,anon,{
  auth:{autoRefreshToken:false,persistSession:false},
  global:{headers:{Authorization:`Bearer ${bearer}`}}
 });
 const {data:{user},error:authError}=await userClient.auth.getUser(bearer);
 if(authError||!user)return NextResponse.json({error:'UNAUTHORIZED'}, {status:401});
 const {data:profile,error:roleError}=await userClient.from('staff_profiles')
  .select('role').eq('user_id',user.id).maybeSingle();
 if(roleError)return NextResponse.json({error:'STAFF_OWNER_PROFILE_LOOKUP_FAILED'}, {status:503});
 if(profile?.role!=='owner')return NextResponse.json({error:'FORBIDDEN_OWNER_ONLY'}, {status:403});

 let payload:unknown;
 try{payload=await request.json()}catch{return NextResponse.json({error:'INVALID_JSON'}, {status:400})}
 if(!payload||typeof payload!=='object'||Array.isArray(payload))
  return NextResponse.json({error:'INVALID_PAYLOAD'}, {status:400});
 const input=payload as Record<string,unknown>;
 const email=typeof input.email==='string'?input.email.trim().toLowerCase():'';
 const name=typeof input.name==='string'?input.name.trim():'';
 if(!email||!name)return NextResponse.json({error:'INVALID_EMAIL_OR_NAME'}, {status:400});

 try{
  const upstream=await fetch(url.replace(/\/+$/,'')+'/functions/v1/dbs-staff-invite',{
   method:'POST',cache:'no-store',
   headers:{'Content-Type':'application/json',apikey:anon,Authorization:`Bearer ${bearer}`},
   body:JSON.stringify({email,name,redirectTo:redirect.toString()})
  });
  let body:Record<string,unknown>;
  try{body=await upstream.json() as Record<string,unknown>}
  catch{body={error:'STAFF_INVITE_UPSTREAM_UNAVAILABLE'}}
  return NextResponse.json(body,{status:upstream.status});
 }catch(e){
  console.error('DBS_STAFF_INVITE_UPSTREAM_NETWORK_ERROR',e instanceof Error?e.message:'Unknown');
  return NextResponse.json({error:'STAFF_INVITE_EDGE_UNAVAILABLE'}, {status:503});
 }
}
