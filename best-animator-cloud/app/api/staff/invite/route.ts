import {NextRequest, NextResponse} from 'next/server';

// This route only forwards an authenticated request. Administrative credentials
// and owner-only authorization remain inside Supabase Edge Functions.
export async function POST(request: NextRequest) {
 const projectUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
 const anonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
 // Always use a stable, project-owned redirect. Preview Vercel deployment URLs
 // change on each build and must never be used for invitation links.
 const redirectTo = process.env.VERCEL_ENV === 'production'
  ? 'https://best-animator-cloud.vercel.app/'
  : 'https://best-animator-cloud-git-feature-owner-manager-f7bf33-s914307771.vercel.app/';
 if (!projectUrl || !anonKey) {
  return NextResponse.json({error:'STAFF_INVITE_NOT_CONFIGURED'}, {status:503});
 }
 const authorization = request.headers.get('authorization') || '';
 if (!/^Bearer\s+\S+$/i.test(authorization)) {
  return NextResponse.json({error:'UNAUTHORIZED'}, {status:401});
 }
 let input:unknown;
 try { input = await request.json(); }
 catch { return NextResponse.json({error:'INVALID_JSON'}, {status:400}); }
 if (!input || typeof input !== 'object' || Array.isArray(input)) {
  return NextResponse.json({error:'INVALID_PAYLOAD'}, {status:400});
 }
 const data=input as Record<string,unknown>;
 const name=typeof data.name==='string'?data.name.trim():'';
 const email=typeof data.email==='string'?data.email.trim().toLowerCase():'';
 if (name.length<2 || name.length>80 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
  return NextResponse.json({error:'INVALID_EMAIL_OR_NAME'}, {status:400});
 }

 try {
  const response=await fetch(projectUrl.replace(/\/+$/,'')+'/functions/v1/dbs-staff-invite',{
   method:'POST',
   cache:'no-store',
   headers:{
    'Content-Type':'application/json',
    'apikey':anonKey,
    'Authorization':authorization,
   },
   body:JSON.stringify({name,email,redirectTo}),
  });
  const responseText=await response.text();
  let result:Record<string,unknown>;
  try {
   const parsed:unknown=JSON.parse(responseText);
   result=parsed && typeof parsed==='object' && !Array.isArray(parsed)
    ? parsed as Record<string,unknown>
    : {error:'STAFF_INVITE_EDGE_INVALID_RESPONSE'};
  } catch {
   result={error:'STAFF_INVITE_EDGE_UNAVAILABLE'};
  }
  return NextResponse.json(result,{status:response.status});
 } catch {
  return NextResponse.json({error:'STAFF_INVITE_EDGE_UNREACHABLE'}, {status:503});
 }
}
