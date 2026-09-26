export const CASES = [
  {id:'1c32cfeb-9f26-427b-8b0d-4d244b5ddcf8',name:'The Pixelverse',tag:'PIXELVERSE',price:200000000,image:'/pixelverse.png',description:'A neon case built around rare pixel rewards.'},
  {id:'5b7d4d72-338a-4afd-8884-bd931a866514',name:'Draconic',tag:'DRACONIC',price:75000000,image:'/draconic1.png',description:'Dragon-themed high tier rewards.'},
  {id:'b2fdbb43-eaf0-4a3d-add3-d4bd84459c8e',name:'Frozen Fury',tag:'FROZEN',price:40000000,image:'/subzero.png',description:'Cold rewards with a high-value ceiling.'},
  {id:'6eb40aaf-7b82-425a-a8a0-ef2eb8ee0f9c',name:'Thunder Skies',tag:'THUNDER',price:25000000,image:'/zeuscase.png',description:'Lightning-fast rewards from the sky.'},
  {id:'85d616cb-83f9-431f-b9e6-8568739819a8',name:'Midnight Howl',tag:'MIDNIGHT',price:300000000,image:'/ghostlycase.png',description:'A dark premium case with a deep reward pool.'},
  {id:'25803f6f-0558-4c99-b5be-459c5bb52baa',name:'A Starry Night',tag:'STARRY',price:50000000,image:'/starrycase.png',description:'Rare night-sky rewards.'},
  {id:'cd5cfaaf-bb96-46d1-af2e-9d0f19db731c',name:'Shadow Case',tag:'SHADOW',price:10000000,image:'/galaxycase.png',description:'A compact case with a surprisingly deep reward pool.'},
  {id:'6bbbd6ee-b389-48af-9a90-7eb23540a66e',name:'Scorching Summer',tag:'SUMMER',price:100000000,image:'/scorchingcase.png',description:'Blaze your way toward a huge reward.'},
  {id:'309d4425-d5e5-43ff-a083-477590662dd5',name:'Gargantuan Vault',tag:'GARGANTUAN',price:500000000,image:'/gargcase.png',description:'The ultimate high-stakes vault.'}
];
export const CASE_TIER_CONFIG = {
  'cd5cfaaf-bb96-46d1-af2e-9d0f19db731c':['HUGE'],
  '6eb40aaf-7b82-425a-a8a0-ef2eb8ee0f9c':['HUGE','TITANIC'],
  'b2fdbb43-eaf0-4a3d-add3-d4bd84459c8e':['HUGE','TITANIC'],
  '25803f6f-0558-4c99-b5be-459c5bb52baa':['HUGE','TITANIC'],
  '5b7d4d72-338a-4afd-8884-bd931a866514':['HUGE','TITANIC'],
  '6bbbd6ee-b389-48af-9a90-7eb23540a66e':['HUGE','TITANIC','GARGANTUAN'],
  '1c32cfeb-9f26-427b-8b0d-4d244b5ddcf8':['HUGE','TITANIC','GARGANTUAN'],
  '85d616cb-83f9-431f-b9e6-8568739819a8':['HUGE','TITANIC','GARGANTUAN'],
  '309d4425-d5e5-43ff-a083-477590662dd5':['HUGE','TITANIC','GARGANTUAN']
};
export const CASE_POOL_CONFIG = Object.fromEntries(CASES.map(c=>[c.id,Object.fromEntries((CASE_TIER_CONFIG[c.id]||['HUGE']).map((tier,i)=>[tier, i===0?1:1]))]));
