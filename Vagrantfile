# -*- mode: ruby -*-
# vi: set ft=ruby :

ENV['VAGRANT_EXPERIMENTAL'] = 'disks'

MACHINES = {
  :'raid-build' => {
    :box => 'generic/centos9s',
    :cpus => 2,
    :memory => 1024,
    :disks => {
      :'generic-centos9s-virtualbox-x64-disk002' => '128GB',
      :disk001 => '100MB',
      :disk002 => '100MB',
      :disk003 => '100MB',
      :disk004 => '100MB',
      :disk005 => '100MB',
      :disk006 => '100MB',
      :disk007 => '100MB',
      :disk008 => '100MB',
      :disk009 => '100MB',
      :disk010 => '100MB',
      :disk011 => '100MB',
      :disk012 => '100MB'
    },
    :script => 'provision.sh'
  }
}

Vagrant.configure('2') do |config|
  MACHINES.each do |host_name, host_config|
    config.vm.define host_name do |host|
      host.vm.box = host_config[:box]
      host.vm.host_name = host_name.to_s

      host.vm.provider :virtualbox do |vb|
        vb.cpus = host_config[:cpus]
        vb.memory = host_config[:memory]
      end

      host_config[:disks].each do |name, size|
        host.vm.disk :disk, name: name.to_s, size: size
      end

      host.vm.provision :shell do |shell|
        shell.path = host_config[:script]
        shell.privileged = false
      end
    end
  end
end
