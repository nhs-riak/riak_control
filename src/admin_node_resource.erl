%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Add/remove/examine node
%%
%%      The resource exposes itself at `/admin/nodes/nodename'.
-module(admin_node_resource).

-export([
         routes/0,
         init/1,
         service_available/2,
         is_authorized/2,
         allowed_methods/2,
         content_types_accepted/2,
         resource_exists/2,
         accept_content/2,
         delete_resource/2,
         delete_completed/2
        ]).

-include_lib("webmachine/include/webmachine.hrl").
-include("riak_control.hrl").

-record(ctx, {
          base_url,
          ring_members,
          nodename
         }).

-type context() :: #ctx{}.
-type method()  :: 'PUT' | 'POST' | 'GET' | 'HEAD' | 'DELETE'.

%%% riak_control_sup API

%% @doc Get the webmachine dispatcher config for this resource.
-spec routes() -> [webmachine_dispatcher:matchterm()].
routes() ->
    [{?ADMIN_BASE_ROUTE++["nodes", 'nodename'],
      ?MODULE,
      [{base_url, ?ADMIN_BASE_PATH++"nodes/"}]}].

%%% Webmachine API

-spec init(list()) -> {ok, context()}.
init(Props) ->
    {base_url, Url} = lists:keyfind(base_url, 1, Props),
    {ok, #ctx{base_url=Url}}.

-spec allowed_methods(wrq:reqdata(), context()) ->
                             {[method()], wrq:request(), context()}.
allowed_methods(RD, Ctx) ->
    {['PUT', 'DELETE'], RD, Ctx}.

-spec service_available(wrq:reqdata(), context()) ->
                               {boolean() | {halt, non_neg_integer()}, wrq:reqdata(), context()}.
service_available(RD, Ctx) ->
    riak_control_security:scheme_is_available(RD, Ctx).

-spec is_authorized(wrq:reqdata(), context()) ->
                           {true | string(), wrq:reqdata(), context()}.
is_authorized(RD, Ctx) ->
    riak_control_security:enforce_auth(RD, Ctx).

-spec content_types_accepted(wrq:reqdata(), context()) ->
                                    {[{ContentType::string(), HandlerFunction::atom()}],
                                     wrq:reqdata(), context()}.
content_types_accepted(RD, Ctx) ->
    CT = case wrq:get_req_header(?HEAD_CTYPE, RD) of
             undefined -> "application/octet-stream";
             X -> X
         end,
    {[{CT, accept_content}], RD, Ctx}.

-spec resource_exists(wrq:reqdata(), context()) ->
                             {boolean(), wrq:reqdata(), context()}.
resource_exists(RD, Ctx) ->
    NewNode = list_to_atom(wrq:path_info(nodename, RD)),
    RingCtx = Ctx#ctx{nodename=NewNode},
    {is_node_in_cluster(NewNode), RD, RingCtx}.

-spec accept_content(wrq:reqdata(), context()) ->
                            {boolean(), wrq:reqdata(), context()}.
accept_content(RD, #ctx{nodename=NewNode}=Ctx) ->
    {ok, OurRingSize} = application:get_env(riak_core, ring_creation_size),
    case net_adm:ping(NewNode) of
        pong ->
            case rpc:call(NewNode,
                          application,
                          get_env,
                          [riak_core, ring_creation_size]) of
                {ok, OurRingSize} ->
                    riak_core_gossip:send_ring(node(), NewNode),
                    {true, RD, Ctx};
                _ ->
                    {{error, <<"different ring sizes">>}, wrq:set_resp_body(<<"different ring sizes">>, RD), Ctx}
            end;
        pang ->
            {{error, <<"node unreachable">>}, wrq:set_resp_body(<<"node unreachable">>, RD), Ctx}
    end.


-spec delete_resource(wrq:reqdata(), context()) ->
                             {boolean(), wrq:reqdata(), context()}.
delete_resource(RD, #ctx{nodename=Node}=Ctx) ->
    try
        case catch(riak_core:remove_from_cluster(Node)) of
            {'EXIT', {badarg, [{erlang, hd, [[]]}|_]}} ->
                {{error, <<"single node">>}, wrq:set_resp_body(<<"Can't remove a single node from 'cluster'">>, RD), Ctx};
            ok ->
                {true, RD, Ctx}
        end
    catch
        Exception:Reason ->
            {{error, Exception}, wrq:set_resp_body(Reason, RD), Ctx}
    end.


-spec delete_completed(wrq:reqdata(), context()) ->
                              {boolean(), wrq:reqdata(), context()}.
delete_completed(RD, #ctx{nodename=Node}=Ctx) ->
    DelComplete =  not is_node_in_cluster(Node),
    {DelComplete, RD, Ctx}.

%% ===================================================================
%% Internal functions
%% ===================================================================
is_node_in_cluster(Node) when is_atom(Node) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    Members = riak_core_ring:all_members(Ring),
    lists:member(Node, Members).
