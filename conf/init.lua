DEBUG = false

local load_config = require "load_config"
config = load_config.parse()

require "init_elasticsearch_templates_data"
require "init_user_agent_parser_data"

ngx.shared.apis:set("config_id", config["config_id"])
ngx.shared.apis:set("upstreams_inited", false)
ngx.shared.apis:delete("nginx_reloading_guard")
ngx.shared.apis:delete("version")
ngx.shared.apis:delete("last_fetched_at")
ngx.shared.config:set("elasticsearch_templates_created", false)
