# frozen_string_literal: true

# Information representing a CI job.
class Job
  NAME_REGEX = /\A(?<runner>\d+(?:\.\d+)?(?:-arm64)?)-(?<run_id>\d+)-(?<run_attempt>\d+)\z/

  attr_reader :runner_name, :repository
  attr_accessor :github_state, :orka_vm_id, :orka_start_attempts
  attr_writer :orka_setup_complete

  def initialize(runner_name, repository)
    @runner_name = runner_name
    @repository = repository
    @github_state = :queued
    @orka_vm_id = nil
    @orka_setup_complete = false
    @orka_start_attempts = 0
  end

  def os
    @runner_name[NAME_REGEX, :runner]
  end

  def arm64?
    os.end_with?("-arm64")
  end

  def run_id
    @runner_name[NAME_REGEX, :run_id]
  end

  def run_attempt
    @runner_name[NAME_REGEX, :run_attempt]
  end

  def orka_setup_complete?
    @orka_setup_complete
  end

  def self.json_create(object)
    job = new(object["runner_name"])
    job.github_state = object["github_state"].to_sym
    job.orka_vm_id = object["orka_vm_id"]
    job.orka_setup_complete = object["orka_setup_complete"]
    job.orka_start_attempts = object["orka_start_attempts"]
    job
  end

  def to_json(*args)
    {
      JSON.create_id        => self.class.name,
      "runner_name"         => @runner_name,
      "github_state"        => @github_state,
      "orka_vm_id"          => @orka_vm_id,
      "orka_setup_complete" => @orka_setup_complete,
      "orka_start_attempts" => @orka_start_attempts,
    }.to_json(*args)
  end
end
