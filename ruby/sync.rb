require 'worker_cast'
if `ls /Applications` != '' # local
  ServerList = {
    app1: 'localhost:9876'
  }
  SelfServer = :app1
else
  ServerList = {
    app1: '192.168.101.1:9876',
    app2: '192.168.101.2:9876',
    app3: '192.168.101.3:9876'
  }
  ifconfig = `ifconfig`
  SelfServer = ServerList.keys.find do |key|
    ip = ServerList[key].split(':').first
    ifconfig.include? ip
  end
end
