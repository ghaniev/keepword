import readline from 'node:readline';
for await(const line of readline.createInterface({input:process.stdin})){
 const m=JSON.parse(line);if(!('id' in m))continue;
 const result=m.method==='initialize'?{protocolVersion:'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'fixture',version:'1'}}:m.method==='tools/list'?{tools:[{name:'create_task',inputSchema:{type:'object',properties:{title:{type:'string'}},required:['title']}}]}:{content:[{type:'text',text:JSON.stringify({id:42,title:m.params.arguments.title})}]};
 process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\n');
}
