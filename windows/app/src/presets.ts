// Ready-made setups for hosted MCP servers of task services; mirrors macos/Sources/MeetNotes/Core/MCP/MCPPresets.swift.
import type {Row} from './api';
export type Lookup={tool:string;value?:string;args?:Record<string,string>};
export type Preset={id:string;name:string;url:string;scope?:string;needsClient?:boolean;taskTool?:string;lookups?:Record<string,Lookup>;hidden?:string[];placeholders?:Record<string,string>;note:string;build?:(item:{title:string;details:string},values:Row)=>Row};
export const notionID=(text:string)=>{const m=text.replace(/-/g,'').match(/[0-9a-fA-F]{32}/g);return m?m[m.length-1]:null};
export const PRESETS:Preset[]=[
 {id:'jira',name:'Jira',url:'https://mcp.atlassian.com/v2/mcp?tools=all',taskTool:'createJiraIssue',
  lookups:{cloudId:{tool:'getAccessibleAtlassianResources'},projectKey:{tool:'listJiraProjects',value:'key',args:{cloudId:'cloudId'}},issueType:{tool:'listJiraProjectIssueTypesMetadata',value:'name',args:{cloudId:'cloudId',projectIdOrKey:'projectKey'}}},
  note:"Atlassian's Rovo MCP server. Sign in with your Atlassian account; an admin may need to allow MCP access first. Choose the site, project and work type once, Keepword remembers them."},
 {id:'linear',name:'Linear',url:'https://mcp.linear.app/mcp',
  lookups:{team:{tool:'list_teams'},teamId:{tool:'list_teams'},project:{tool:'list_projects'},projectId:{tool:'list_projects'},assignee:{tool:'list_users'},assigneeId:{tool:'list_users'}},
  note:"Linear's MCP server. Sign in with your Linear account, or remove \"auth\" and put an API key in headers as Authorization: Bearer <key>."},
 {id:'notion',name:'Notion',url:'https://mcp.notion.com/mcp',taskTool:'notion-create-pages',hidden:['pages','allow_async','creation_mode','is_skill'],
  placeholders:{parent:'Notion page link (empty: a private page)'},note:"Notion's MCP server. Each action item becomes a page under the page you choose.",
  build:(item,values)=>{const args:Row={pages:[{properties:{title:item.title},content:item.details}]};const id=notionID(String(values.parent??''));if(id)args.parent={page_id:id};return args}},
 {id:'asana',name:'Asana',url:'https://mcp.asana.com/v2/mcp',scope:'',needsClient:true,
  note:"Asana's MCP server needs an OAuth app: create an MCP app at app.asana.com/0/my-apps with the redirect URL http://localhost:47821/callback, make it available to your workspace, then fill in clientId and clientSecret."},
 {id:'miro',name:'Miro',url:'https://mcp.miro.com/',note:"Miro's MCP server. Sign in and pick a team. Miro adds items to boards with its own tools; choose one in the task form."},
];
export const findPreset=(id?:string)=>PRESETS.find(p=>p.id===id);
/** Server entry for settings.servers; secrets (clientSecret, headers) move to Credential Manager on save. */
export function presetServer(p:Preset):Row{const s:Row={id:crypto.randomUUID(),name:p.name,transport:'http',url:p.url,auth:'oauth',preset:p.id};if(p.scope!==undefined)s.scope=p.scope;if(p.taskTool)s.taskTool=p.taskTool;if(p.needsClient){s.clientId='';s.clientSecret=''}return s}
