#!/bin/env ruby

require 'thor'
require 'thor/group'
require 'mustache'
require 'uri'

NGINX_TEMPLATE = <<EONGINXCONF
  upstream {{name}}_upstream {
    server unix:{{rails_root}}/tmp/unicorn.{{name}}.sock fail_timeout=0;
  }

  server {
    listen *:80; # default deferred; # for Linux

    access_log  /var/log/nginx/{{name}}.access_log main;
    error_log  /var/log/nginx/{{name}}.error_log;

    client_max_body_size 4G;
    server_name {{hostname}};

    # ~2 seconds is often enough for most folks to parse HTML/CSS and
    # retrieve needed images/icons/frames, connections are cheap in
    # nginx so increasing this is generally safe...
    keepalive_timeout 15;

    # path for static files
    root {{rails_root}}/public;

    # Prefer to serve static files directly from nginx to avoid unnecessary
    # data copies from the application server.
    #
    # try_files directive appeared in in nginx 0.7.27 and has stabilized
    # over time.  Older versions of nginx (e.g. 0.6.x) requires
    # "if (!-f $request_filename)" which was less efficient:
    # http://bogomips.org/unicorn.git/tree/examples/nginx.conf?id=v3.3.1#n127
    try_files $uri/index.html $uri.html $uri @app;

    location @app {
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header Host $http_host;
      proxy_redirect off;
      proxy_pass http://{{name}}_upstream;
    }

    # Rails error pages
    error_page 500 502 503 504 /500.html;
    location = /500.html {
      root {{rails_root}}/public;
    }
  }
EONGINXCONF

UNICORN_TEMPLATE = %q{
rails_env = "{{mode}}"

worker_processes rails_env == 'production' ? 16 : 4

# Help ensure your application will always spawn in the symlinked
# "current" directory that Capistrano sets up.
working_directory "{{rails_root}}"


# listen on both a Unix domain socket and a TCP port,
# we use a shorter backlog for quicker failover when busy
listen "{{rails_root}}/tmp/unicorn.{{name}}.sock", :backlog => 64
# listen 54018, :tcp_nopush => true

# nuke workers after 30 seconds instead of 60 seconds (the default)
timeout 180

# feel free to point this anywhere accessible on the filesystem
pid "/var/run/unicorn/{{name}}.pid"

stderr_path "/var/log/unicorn/{{name}}.stderr.log"
stdout_path "/var/log/unicorn/{{name}}.stdout.log"

preload_app true
GC.respond_to?(:copy_on_write_friendly=) and
  GC.copy_on_write_friendly = true

before_fork do |server, worker|
  defined?(ActiveRecord::Base) and
    ActiveRecord::Base.connection.disconnect!

  old_pid = "#{server.config[:pid]}.oldbin"
  puts "#{server.pid}"
  if File.exists?(old_pid) && server.pid != old_pid
    begin
      Process.kill("QUIT", File.read(old_pid).to_i)
    rescue Errno::ENOENT, Errno::ESRCH
      puts "Error sending QUIT"
    end
  end
  sleep 1
end

after_fork do |server, worker|
  process_pid = worker.nr

  child_pid = server.config[:pid].sub('.pid', ".#{process_pid}.pid")
  File.open(child_pid, "w") do |f|
    f.puts Process.pid
  end

  defined?(ActiveRecord::Base) and
    ActiveRecord::Base.establish_connection rails_env.to_sym

end
}

INIT_TEMPLATE = %q[#!/sbin/runscript
# Copyright 1999-2009 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

# opts="${opts} upgrade reload force-stop rotate kill_worker"

extra_commands="reload upgrade force-stop rotate kill_worker"

PIDDIR=/var/run/unicorn
LOGDIR=/var/log/unicorn
UNICORN_INSTANCE="${SVCNAME#*.}"
UNICORN_USER="${UNICORN_USER:-nginx}"
UNICORN_GROUP="${UNICORN_GROUP:-rvm}"
UNICORN_CMD="unicorn_rails"
UNICORN_CONFIG="/etc/unicorn/{{name}}.rb"
### RAILS_ENV="${RAILS_ENV:-production}"
RAILS_ENV="${RAILS_ENV:-development}"
APP_ROOT="{{rails_root}}"
PID="${PIDDIR}/${UNICORN_INSTANCE}.pid"
DAEMON="${UNICORN_CMD}"
DAEMON_OPTS="-D -E $RAILS_ENV -c $UNICORN_CONFIG"
#SET_PATH="export PATH=${PATH}:/usr/local/bin ; cd $APP_ROOT" 

CMD="cd $APP_ROOT; /usr/local/rvm/bin/{{name}}_unicorn_rails $DAEMON_OPTS"

old_pid="$PID.oldbin"

cd $APP_ROOT || eend 1

depend() {
	need net
	use nginx mysql
	after nginx mysql
}

sig () {
  test -s "$PID" && kill -$1 `cat $PID`
}

oldsig () {
  test -s $old_pid && kill -$1 `cat $old_pid`
}

workersig () {
  workerpid="${PIDDIR}/${UNICORN_INSTANCE}.$2.pid"

  test -s $workerpid && kill -$1 `cat $workerpid`
}

start() {
	[ ! -d ${PIDDIR} ] && mkdir -p ${PIDDIR}
	[ ! -d ${LOGDIR} ] && mkdir -p ${LOGDIR}

  if [ ! -f "${UNICORN_CONFIG}" ];
  then
    eerror "No configuration file for ${UNICORN_INSTANCE}"
    eend 1
    return
  fi

	ebegin "Starting unicorn for ${UNICORN_INSTANCE}"
  sig 0 && eerror "${UNICORN_INSTANCE} Already running" && eend 1 && return
  #$UNICORN_CMD -D -E $RAILS_ENV --config /etc/unicorn/${UNICORN_INSTANCE}
  ### start-stop-daemon --start --quiet \
  ###                   -e HOME=/home/xymox \
  ###                   --chdir $APP_ROOT \
  ###                   --chuid $UNICORN_USER:$UNICORN_GROUP \
  ###                   --exec $DAEMON -- $DAEMON_OPTS
  echo $CMD
  #su - $UNICORN_USER -c "/usr/local/bin/rvm-shell -c '$CMD'"
  ### su - $UNICORN_USER -c "$CMD"
  su - root -c "$CMD"
  #su - $UNICORN_USER -c '/usr/local/bin/rvm-shell -c "unicorn -c /etc/unicorn/pureftpd-admin.rb -D "'
	eend $?
}

stop() {
	ebegin "Stopping unicorn for ${UNICORN_INSTANCE}"
  sig TERM
  if [ $? != 0 ];
  then 
    eerror "${UNICORN_INSTANCE} Not running"
    eend 1
    return
  fi
	eend $?
}

kill_worker() {
  einfo "params $@"
  einfo "Worker $1"
  workersig QUIT $1 && eend 0 && return
  eerror "Worker $1 not running"
  shift
  eend 1
}

reload() {
  sig USR2 && einfo "reloaded OK" && eend 0 && return
  eerror "Not running"
  eend 1
}

upgrade() {
  sig USR2 && einfo "upgrade OK" && eend 0 && return
  eerror "Couldn't upgrade, starting '$UNICORN_CMD' instead"
  $UNICORN_CMD
  eend $?
}

rotate() {
  sig USR1 && einfo "rotated logs OK" && eend 0 && return
  eerror "Couldn't rotate logs"
  eend 1
}

restart() {
	svc_stop
	svc_start
}
]

class CreateAppConfigGenerator < Thor::Group
  include Thor::Actions

  desc "create nginx unicorn config files for rails app"

  argument :name
  class_option :url
  class_option :mode, :default => :development
  class_option :dirname

  def self.source_root
    File.dirname(__FILE__)
  end

  def create_nginx_config
    mode = options[:mode]
    create_file "/etc/nginx/vhosts/http/available/#{hostname}.conf" do
      Mustache.render(NGINX_TEMPLATE, :name => name, :mode => mode, :hostname => hostname, :dirname => dirname, :rails_root => rails_root)
    end
  end

  def create_unicorn_config
    mode = options[:mode]
    create_file "/etc/unicorn/#{name}.rb" do
      Mustache.render(UNICORN_TEMPLATE, :name => name, :mode => mode, :hostname => hostname, :dirname => dirname, :rails_root => rails_root)
    end
  end

  def do_initd
    mode = options[:mode]
    create_file "/etc/init.d/unicorn.#{name}" do
      Mustache.render(INIT_TEMPLATE, :name => name, :mode => mode, :hostname => hostname, :dirname => dirname, :rails_root => rails_root)
    end
    chmod("/etc/init.d/unicorn.#{name}", 0755)
  end

  def url
    url = if options[:url].nil? || options[:url].strip == ''
      "http://#{name}.devel.dotgee.fr"
    else
      URI(options[:url]).to_s
    end
    url
  end
  remove_task :url

  def hostname
    URI(url).hostname
  end
  remove_task :hostname

  def dirname
    return options[:dirname].to_s unless options[:dirname].nil? || options[:dirname].strip == ''
    name
  end
  remove_task :dirname

  def rails_root
    File.join('/var/www/app/rails', options[:mode].to_s, dirname)
  end
  remove_task :rails_root
end

CreateAppConfigGenerator.start

