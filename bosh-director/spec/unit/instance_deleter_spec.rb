require 'spec_helper'

module Bosh::Director
  describe InstanceDeleter do
    before { allow(App).to receive_message_chain(:instance, :blobstores, :blobstore).and_return(blobstore) }
    let(:blobstore) { instance_double('Bosh::Blobstore::Client') }
    let(:domain) { Models::Dns::Domain.make(name: 'bosh') }
    let(:cloud) { instance_double('Bosh::Cloud') }
    before { allow(Config).to receive(:cloud).and_return(cloud) }

    let(:ip_provider) { instance_double(DeploymentPlan::IpProvider) }
    let(:dns_manager) { instance_double(DnsManager, delete_dns_for_instance: nil) }
    let(:options) { {} }
    let(:deleter) { InstanceDeleter.new(ip_provider, dns_manager, disk_manager, options) }
    let(:disk_manager) { DiskManager.new(cloud, logger) }

    describe '#delete_instance_plans' do
      let(:network_plan) { DeploymentPlan::NetworkPlanner::Plan.new(reservation: reservation) }

      let(:existing_instance) { Models::Instance.make(vm: vm.model, deployment: deployment_model, uuid: 'uuid-1', job: 'fake-job-name', index: 5) }

      let(:instance_plan) do
        DeploymentPlan::InstancePlan.new(
          existing_instance: existing_instance,
          instance: nil,
          network_plans: [network_plan],
          desired_instance: nil,
          skip_drain: true
        )
      end

      let(:instance_plans_to_delete) do
        instance_plans = []
        5.times { instance_plans << instance_plan }
        instance_plans
      end

      let(:instances_to_delete) do
        instances = []
        5.times { instances << instance_plan.instance }
        instances
      end

      let(:event_log_stage) { instance_double('Bosh::Director::EventLog::Stage') }

      describe 'deleting instances' do
        before do
          allow(event_log_stage).to receive(:advance_and_track).and_yield
        end

        let(:vm) do
          vm = DeploymentPlan::Vm.new
          vm.model = Models::Vm.make(cid: 'fake-vm-cid')
          vm
        end
        let(:network) { instance_double(DeploymentPlan::ManualNetwork, name: 'manual-network') }
        let(:reservation) do
          az = DeploymentPlan::AvailabilityZone.new('az', {})
          instance = DeploymentPlan::Instance.create_from_job(job, 5, {}, deployment_plan, 'started', az, logger)
          reservation = DesiredNetworkReservation.new(instance, network, '192.168.1.2', :dynamic)
          reservation.mark_reserved

          reservation
        end

        let(:deployment_model) { Models::Deployment.make(name: 'deployment-name') }
        let(:job) { DeploymentPlan::Job.new(logger) }
        let(:deployment_plan) { instance_double(DeploymentPlan::Planner, ip_provider: ip_provider, model: deployment_model) }

        let(:stopper) { instance_double(Stopper) }
        before do
          allow(Stopper).to receive(:new).with(
              instance_plan,
              'stopped',
              Config,
              logger
            ).and_return(stopper)
        end

        let(:job_templates_cleaner) do
          job_templates_cleaner = instance_double('Bosh::Director::RenderedJobTemplatesCleaner')
          allow(RenderedJobTemplatesCleaner).to receive(:new).with(existing_instance, blobstore, logger).and_return(job_templates_cleaner)
          job_templates_cleaner
        end

        let(:persistent_disks) do
          disk = Models::PersistentDisk.make(disk_cid: 'fake-disk-cid-1')
          Models::Snapshot.make(persistent_disk: disk)
          [Models::PersistentDisk.make(disk_cid: 'instance-disk-cid'), disk]
        end

        before do
          persistent_disks.each { |disk| existing_instance.persistent_disks << disk }
        end

        it 'should delete the instances with the config max threads option' do
          allow(Config).to receive(:max_threads).and_return(5)
          pool = double('pool')
          allow(ThreadPool).to receive(:new).with(max_threads: 5).and_return(pool)
          allow(pool).to receive(:wrap).and_yield(pool)
          allow(pool).to receive(:process).and_yield

          5.times do |index|
            expect(deleter).to receive(:delete_instance_plan).with(
                instance_plans_to_delete[index],
                event_log_stage
              )
          end

          deleter.delete_instance_plans(instance_plans_to_delete, event_log_stage)
        end

        it 'should delete the instances with the respected max threads option' do
          pool = double('pool')
          allow(ThreadPool).to receive(:new).with(max_threads: 2).and_return(pool)
          allow(pool).to receive(:wrap).and_yield(pool)
          allow(pool).to receive(:process).and_yield

          5.times do |index|
            expect(deleter).to receive(:delete_instance_plan).with(
                instance_plans_to_delete[index], event_log_stage)
          end

          deleter.delete_instance_plans(instance_plans_to_delete, event_log_stage, max_threads: 2)
        end

        it 'drains, deletes snapshots, dns records, persistent disk, releases old reservations' do
          expect(stopper).to receive(:stop)
          expect(dns_manager).to receive(:delete_dns_for_instance).with(existing_instance)
          expect(cloud).to receive(:delete_vm).with(vm.model.cid)
          expect(ip_provider).to receive(:release).with(reservation)

          expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/uuid-1 (5)')

          job_templates_cleaner = instance_double('Bosh::Director::RenderedJobTemplatesCleaner')
          allow(RenderedJobTemplatesCleaner).to receive(:new).with(existing_instance, blobstore, logger).and_return(job_templates_cleaner)
          expect(job_templates_cleaner).to receive(:clean_all).with(no_args)
          expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)

          deleter.delete_instance_plans([instance_plan], event_log_stage)

          expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
        end

        context 'when force option is passed in' do
          let(:options) { {force: true} }

          context 'when stopping fails' do
            before do
              allow(stopper).to receive(:stop).and_raise(RpcTimeout)
            end

            it 'deletes snapshots, persistent disk, releases old reservations' do
              expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
              expect(dns_manager).to receive(:delete_dns_for_instance).with(existing_instance)
              expect(cloud).to receive(:delete_vm).with(vm.model.cid)
              expect(ip_provider).to receive(:release).with(reservation)

              expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/uuid-1 (5)')

              expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

              deleter.delete_instance_plans([instance_plan], event_log_stage)

              expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
            end
          end

          context 'when deleting vm fails' do
            before do
              allow(cloud).to receive(:delete_vm).and_raise(
                  Bosh::Clouds::CloudError.new('Failed to create VM')
                )
            end

            it 'drains, deletes snapshots, persistent disk, releases old reservations' do
              expect(stopper).to receive(:stop)
              expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
              expect(dns_manager).to receive(:delete_dns_for_instance).with(existing_instance)
              expect(ip_provider).to receive(:release).with(reservation)

              expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/uuid-1 (5)')

              expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

              deleter.delete_instance_plans([instance_plan], event_log_stage)

              expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
            end
          end

          context 'when deleting dns fails' do
            before do
              allow(dns_manager).to receive(:delete_dns_for_instance).and_raise('failed')
            end

            it 'drains, deletes vm, snapshots, disks, releases old reservations' do
              expect(stopper).to receive(:stop)
              expect(cloud).to receive(:delete_vm).with(vm.model.cid)
              expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
              expect(ip_provider).to receive(:release).with(reservation)

              expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/uuid-1 (5)')

              expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

              deleter.delete_instance_plans([instance_plan], event_log_stage)

              expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
            end
          end

          context 'when cleaning templates fails' do
            before do
              allow(job_templates_cleaner).to receive(:clean_all).and_raise('failed')
            end

            it 'drains, deletes vm, snapshots, disks, releases old reservations' do
              expect(stopper).to receive(:stop)
              expect(cloud).to receive(:delete_vm).with(vm.model.cid)
              expect(disk_manager).to receive(:delete_persistent_disks).with(existing_instance)
              expect(ip_provider).to receive(:release).with(reservation)

              expect(event_log_stage).to receive(:advance_and_track).with('fake-job-name/uuid-1 (5)')
              expect(job_templates_cleaner).to receive(:clean_all).with(no_args)

              deleter.delete_instance_plans([instance_plan], event_log_stage)

              expect(Models::Vm.find(cid: 'fake-vm-cid')).to eq(nil)
            end
          end
        end
      end
    end
  end
end
