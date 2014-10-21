{application,gen_bunny,
             [{description,"gen_bunny"},
              {vsn,"0.1"},
              {modules,[bunny_util,bunnyc,gen_bunny,gen_bunny_app,
                        gen_bunny_mon,gen_bunny_sup,push_consumer,test_gb]},
              {registered,[]},
              {mod,{gen_bunny_app,[]}},
              {env,[
              		{connections, [{gen_bunny_rabbit1,
									{"192.168.241.3", 5672, {<<"guest">>, <<"guest">>}, <<"/">>},
			      					{[{<<"push1">>, []}], 
			      	 				 [{<<"android1">>, []},{<<"ios1">>, []}], 
			      	 				 [{<<"push1">>, <<"android1">>, <<"push.android">>},{<<"push1">>, <<"ios1">>, <<"push.ios">>}]
			      					}},
			  					   {gen_bunny_rabbit2,
									{"192.168.241.5", 5672, {<<"guest">>, <<"guest">>}, <<"/">>},
			      					{[{<<"push2">>, []}], 
			      	 				 [{<<"android2">>, []},{<<"ios2">>, []}], 
			      	 				 [{<<"push2">>, <<"android2">>, <<"push.android">>},{<<"push2">>, <<"ios2">>, <<"push.ios">>}]
			      				}}]}]},
              {applications,[kernel,stdlib,amqp_client,rabbit_common]}]}.
