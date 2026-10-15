/** Illustrative local messages; never presented as real audience activity. */
export const sampleMessages = [
  {username:'sample_alex', badges:[], text:'That corner was so clean. 🏁'},
  {username:'sample_luna', badges:[{type:'subscriber',text:'CREW'}], text:'Llegando a la sesión [demo:hi]'},
  {username:'sample_nico', badges:[], text:'The ice-blue setup looks incredible.'},
  {username:'sample_maya', badges:[{type:'moderator',text:'MOD'}], text:'Welcome to the ride. English y español, siempre.'},
  {username:'sample_racer', badges:[], text:'Una vuelta más. [demo:gg]'},
  {username:'sample_crew', badges:[{type:'subscriber',text:'CREW'}], text:'Build. Code. Race. [demo:heart]'},
  {username:'sample_skadi', badges:[], text:'Next stop: the workshop. What are we building today?'},
  {username:'sample_ana', badges:[], text:'¡Ese adelantamiento estuvo buenísimo!'},
  {username:'sample_rider', badges:[], text:'Good company, late-night laps. [demo:gg]'}
];

export function startDemo(view) {
  let count=0;
  const add=()=> { const message=sampleMessages[count%sampleMessages.length]; view.add({...message,id:`demo-${Date.now()}-${count}`,platform:'kick',userId:message.username,createdAt:new Date().toISOString(),demo:true}); count++; };
  for(let index=0;index<5;index++) add();
  const timer=setInterval(add,4200);
  return ()=>clearInterval(timer);
}
