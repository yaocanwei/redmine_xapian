#!/usr/bin/ruby -W0

# encoding: utf-8
#
# Redmine Xapian is a Redmine plugin to allow attachments searches by content.
#
# Copyright © 2010    Xabier Elkano
# Copyright © 2015-18 Karel Pičman <karel.picman@kontron.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require 'optparse'

include Rails.application.routes.url_helpers

########################################################################################################################
# BEGIN Configuration parameters
# Configure the following parameters (most of them can be configured through the command line):
########################################################################################################################

# Redmine installation directory
$redmine_root = File.expand_path('../../../../', __FILE__)

# Files location
$files = 'files'

# scriptindex binary path 
$scriptindex  = '/usr/bin/scriptindex'

# omindex binary path
$omindex      = '/usr/bin/omindex'

# Directory containing Xapian databases for omindex (Attachments indexing)
$dbrootpath = File.expand_path('file_index', $redmine_root)

# Verbose output, values of 0 no verbose, greater than 0 verbose output
$verbose      = 0

# Define stemmed languages to index attachments Eg. [ 'english', 'italian', 'spanish' ]
# Repository database will be always indexed in english
# Available languages are danish dutch english finnish french german german2 hungarian italian kraaij_pohlmann lovins
# norwegian porter portuguese romanian russian spanish swedish turkish:
$stem_langs	= ['english']

# Project identifiers whose repositories will be indexed eg. [ 'prj_id1', 'prj_id2' ]
# Use [] to index all projects
$projects	= []

# Temporary directory for indexing, it can be tmpfs
$tempdir	= '/tmp'

# Binaries for text conversion
$pdftotext = '/usr/bin/pdftotext -enc UTF-8'
$antiword	 = '/usr/bin/antiword'
$catdoc		 = '/usr/bin/catdoc'
$xls2csv	 = '/usr/bin/xls2csv'
$catppt		 = '/usr/bin/catppt'
$unzip		 = '/usr/bin/unzip -o'
$unrtf		 = '/usr/bin/unrtf -t text 2>/dev/null'

########################################################################################################################
# END Configuration parameters
########################################################################################################################

$environment = File.join($redmine_root, 'config/environment.rb')
$project = nil
$databasepath = nil
$repositories = nil
$onlyfiles = nil
$onlyrepos = nil
$env = 'production'
$resetlog = nil
$retryfailed = nil

MIME_TYPES = {
  'application/pdf' => 'pdf',
  'application/rtf' => 'rtf',
  'application/msword' => 'doc',
  'application/vnd.ms-excel' => 'xls',
  'application/vnd.ms-powerpoint' => 'ppt,pps',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation' => 'pptx',
  'application/vnd.openxmlformats-officedocument.presentationml.slideshow' => 'ppsx',
  'application/vnd.oasis.opendocument.spreadsheet' => 'ods',
  'application/vnd.oasis.opendocument.text' => 'odt',
  'application/vnd.oasis.opendocument.presentation' => 'odp',
  'application/javascript' => 'js'
}.freeze


FORMAT_HANDLERS = {
  pdf: $pdftotext,
  doc: $catdoc,
  xls: $xls2csv,
  ppt: $catppt,
  pps: $catppt,
  docx: $unzip,
  xlsx: $unzip,
  pptx: $unzip,
  ppsx: $unzip,
  ods: $unzip,
  odt: $unzip,
  odp: $unzip,
  rtf: $unrtf
}.freeze

VERSION = '0.2'.freeze

optparse = OptionParser.new do |opts|
  opts.banner = 'Usage: xapian_indexer.rb [OPTIONS...]'
  opts.separator('')
  opts.separator('Index redmine files and repositories')
  opts.separator('')  
  opts.separator('')
  opts.separator('Options:')
  opts.on('-p', '--projects a,b,c', Array,
          'Comma separated list of projects whose repositories will be indexed') { |p| $projects = p }
  opts.on('-s', '--stemming_lang a,b,c', Array,
          'Comma separated list of stemming languages for indexing') { |s| $stem_langs = s }
  opts.on('-v', '--verbose',            'verbose') {$verbose += 1}
  opts.on('-f', '--files',              'Only index Redmine attachments') { $onlyfiles = 1 }
  opts.on('-r', '--repositories',       'Only index Redmine repositories') { $onlyrepos = 1 }
  opts.on('-e', '--environment ENV',
          'Rails ENVIRONMENT (development, testing or production), default production') { |e| $env = e}
  opts.on('-t', '--temp-dir PATH',      'Temporary directory for indexing'){ |t| $tempdir = t }  
  opts.on('-x', '--resetlog',           'Reset index log'){  $resetlog = 1 }
  opts.on('-V', '--version',            'show version and exit') { puts VERSION; exit}
  opts.on('-h', '--help',               'show help and exit') { puts opts; exit }
  opts.on('-R', '--retry-failed', 'retry files which omindex failed to extract text') { $retryfailed = 1 }
  opts.separator('')
  opts.separator('Examples:')
  opts.separator('  xapian_indexer.rb -f -s english,italian -v')
  opts.separator('  xapian_indexer.rb -p project_id -x -t /tmpfs -v')
  opts.separator('')
  opts.summary_width = 25
end

optparse.parse!

ENV['RAILS_ENV'] = $env

STATUS_SUCCESS = 1
STATUS_FAIL = -1
ADD_OR_UPDATE = 1
DELETE = 0
 
class IndexingError < StandardError; end

def repo_name(repository)
  repository.identifier.blank? ? 'main' : repository.identifier
end

def indexing(databasepath, project, repository)    
    logger "Fetch changesets: #{project.name} - #{repo_name(repository)}"
    repository.fetch_changesets    
    repository.reload.changesets.reload    

    latest_changeset = repository.changesets.first    
    return unless latest_changeset    

    logger "Latest revision: #{project.name} - #{repo_name(repository)} - #{latest_changeset.revision}"
    latest_indexed = Indexinglog.where(:repository_id => repository.id, :status => STATUS_SUCCESS).last
    logger "Latest indexed: #{latest_indexed.inspect}"
    begin
      indexconf = Tempfile.new('index.conf', $tempdir)
      indexconf.write "url : field boolean=Q unique=Q\n"
      indexconf.write "body : index truncate=400 field=sample\n"
      indexconf.write "date: field=date\n"
      indexconf.close
      if latest_indexed
        logger "Repository #{repo_name(repository)} indexed, indexing diff"
        indexing_diff(databasepath, indexconf, project, repository,
                      latest_indexed.changeset, latest_changeset)
      else
        logger "Repository #{repo_name(repository)} not indexed, indexing all"
        indexing_all(databasepath, indexconf, project, repository)
      end
      indexconf.unlink
    rescue IndexingError => e
      add_log(repository, latest_changeset, STATUS_FAIL, e.message)
    else
      add_log(repository, latest_changeset, STATUS_SUCCESS)
      logger "Successfully indexed: #{project.name} - #{repo_name(repository)} - #{latest_changeset.revision}"
    end
end

def supported_mime_type(entry)
  mtype = Redmine::MimeType.of(entry)    
  MIME_TYPES.include?(mtype) || Redmine::MimeType.is_type?('text', entry)
end

def add_log(repository, changeset, status, message = nil)
  log = Indexinglog.where(:repository_id => repository.id).last
  if log
    log.changeset_id = changeset.id
    log.status = status
    log.message = message if message
    log.save!
    logger "Log for repo #{repo_name(repository)} updated!"
  else
    log = Indexinglog.new
    log.repository = repository
    log.changeset = changeset
    log.status = status
    log.message = message if message
    log.save!
    logger "New log for repo #{repo_name(repository)} saved!"
  end
end

def update_log(repository, changeset, status, message = nil)
  log = Indexinglog.where(:repository_id => repository.id).last
  if log
    log.changeset_id = changeset.id
    log.status = status if status
    log.message = message if message
    log.save!
    logger "Log for repo #{repo_name(repository)} updated!"    
  end
end

def delete_log(repository)
  Indexinglog.where(:repository_id => repository.id).delete_all
  logger "Log for repo #{repo_name(repository)} removed!"  
end

def walk(databasepath, indexconf, project, repository, identifier, entries)  
  return if entries.nil? || entries.size < 1
  logger "Walk entries size: #{entries.size}"
  entries.each do |entry|
    logger "Walking into: #{entry.lastrev.time}" if entry.lastrev
    if entry.is_dir?
      walk(databasepath, indexconf, project, repository, identifier, repository.entries(entry.path, identifier))
    elsif entry.is_file? && !entry.lastrev.nil?
      add_or_update_index(databasepath, indexconf, project, repository, identifier, entry.path, 
        entry.lastrev, ADD_OR_UPDATE, MIME_TYPES[Redmine::MimeType.of(entry.path)]) if supported_mime_type(entry.path)	
    end
  end
end

def indexing_all(databasepath, indexconf, project, repository)  
  logger "Indexing all: #{repo_name(repository)}"
  begin
    if repository.branches
      repository.branches.each do |branch|
        logger "Walking in branch: #{repo_name(repository)} - #{branch}"
        walk(databasepath, indexconf, project, repository, branch, repository.entries(nil, branch))
      end
    else
      logger "Walking in branch: #{repo_name(repository)} - [NOBRANCH]"
      walk(databasepath, indexconf, project, repository, nil, repository.entries(nil, nil))
    end
    if repository.tags
      repository.tags.each do |tag|
        logger "Walking in tag: #{repo_name(repository)} - #{tag}"
        walk(databasepath, indexconf, project, repository, tag, repository.entries(nil, tag))
      end
    end
  rescue Exception => e
    logger "#{repo_name(repository)} encountered an error and will be skipped: #{e.message}", true
  end
end

def walkin(databasepath, indexconf, project, repository, identifier, changesets)
    logger "Walking into #{changesets.inspect}"
    return unless changesets or changesets.size <= 0
    changesets.sort! { |a, b| a.id <=> b.id }

    actions = Hash::new
    # SCM actions
    #   * A - Add
    #   * M - Modified
    #   * R - Replaced
    #   * D - Deleted
    changesets.each do |changeset|
      logger "Changeset changes for #{changeset.id} #{changeset.filechanges.inspect}"
      next unless changeset.filechanges
      changeset.filechanges.each do |change|        
        actions[change.path] = (change.action == 'D') ? DELETE : ADD_OR_UPDATE        
      end
    end
    return unless actions
    actions.each do |path, action|
      entry = repository.entry(path, identifier)
      if (entry && entry.is_file?) || (action == DELETE)
        if entry.nil? && (action != DELETE)
          log("Error indexing path: #{path.inspect}, action: #{action.inspect}, identifier: #{identifier.inspect}",
              true)
        end
        logger "Entry to index #{entry.inspect}"
        lastrev = entry.lastrev if entry
        if supported_mime_type(path) || (action == DELETE)
          add_or_update_index(databasepath, indexconf, project, repository, identifier, path, lastrev, action,
                              MIME_TYPES[Redmine::MimeType.of(path)])
        end
      end
    end
  end

def indexing_diff(databasepath, indexconf, project, repository, diff_from, diff_to)  
  if diff_from.id >= diff_to.id
    logger "Already indexed: #{repo_name(repository)} (from: #{diff_from.id} to #{diff_to.id})"    
    return
  end

	logger "Indexing diff: #{repo_name(repository)} (from: #{diff_from.id} to #{diff_to.id})"
	logger "Indexing all: #{repo_name(repository)}"
  
	if repository.branches
    repository.branches.each do |branch|
    logger "Walking in branch: #{repo_name(repository)} - #{branch}"
    walkin(databasepath, indexconf, project, repository, branch, repository.latest_changesets('', branch,
      diff_to.id - diff_from.id).select { |changeset| changeset.id > diff_from.id and changeset.id <= diff_to.id})
	end
	else
    logger "Walking in branch: #{repo_name(repository)} - [NOBRANCH]"
    walkin(databasepath, indexconf, project, repository, nil, repository.latest_changesets('', nil,
      diff_to.id - diff_from.id).select { |changeset| changeset.id > diff_from.id and changeset.id <= diff_to.id})
	end
	if repository.tags
    repository.tags.each do |tag|
      logger "Walking in tag: #{repo_name(repository)} - #{tag}"
      walkin(databasepath, indexconf, project, repository, tag, repository.latest_changesets('', tag,
        diff_to.id - diff_from.id).select { |changeset| changeset.id > diff_from.id and changeset.id <= diff_to.id})
    end
	end
end

def generate_uri(project, repository, identifier, path)
	url_for(:controller => 'repositories',
			:action => 'entry',
			:id => project.identifier,
			:repository_id => repository.identifier,
			:rev => identifier,
			:path => repository.relative_path(path),
			:only_path => true)
end

def convert_to_text(fpath, type)
  text = nil
  return text unless File.exist?(FORMAT_HANDLERS[type].split(' ').first)
  case type
    when 'pdf'    
      text = `#{FORMAT_HANDLERS[type]} #{fpath} -`
    when /(xlsx|docx|odt|pptx)/i
      system "#{$unzip} -d #{$tempdir}/temp #{fpath} > /dev/null", :out=>'/dev/null'
      case type
        when 'xlsx'
          fout = "#{$tempdir}/temp/xl/sharedStrings.xml"
        when 'docx'
          fout = "#{$tempdir}/temp/word/document.xml"
        when 'odt'
          fout = "#{$tempdir}/temp/content.xml"
        when 'pptx'
          fout = "#{$tempdir}/temp/docProps/app.xml"
        end                
      begin
        text = File.read(fout)
        FileUtils.rm_rf("#{$tempdir}/temp") 
      rescue Exception => e
        logger "Error: #{e.to_s} reading #{fout}", true
      end
    else
      text = `#{FORMAT_HANDLERS[type]} #{fpath}`
  end
  text
end

def add_or_update_index(databasepath, indexconf, project, repository, identifier, 
    path, lastrev, action, type)  
  uri = generate_uri(project, repository, identifier, path)
  return unless uri
  text = nil
  if Redmine::MimeType.is_type?('text', path) || (%(js).include?(type))
    text = repository.cat(path, identifier)
  else
    fname = path.split('/').last.tr(' ', '_')
    bstr = repository.cat(path, identifier)
    File.open( "#{$tempdir}/#{fname}", 'wb+') do | bs |
      bs.write(bstr)
    end
    text = convert_to_text("#{$tempdir}/#{fname}", type) if File.exist?("#{$tempdir}/#{fname}") and !bstr.nil?
    File.unlink("#{$tempdir}/#{fname}")
  end  
  logger "generated uri: #{uri}"
  log('Mime type text') if  Redmine::MimeType.is_type?('text', path)
  logger "Indexing: #{path}"
  begin
    itext = Tempfile.new('filetoindex.tmp', $tempdir) 
    itext.write("url=#{uri.to_s}\n")
    if action != DELETE
      sdate = lastrev.time || Time.at(0).in_time_zone
      itext.write("date=#{sdate.to_s}\n")
      body = nil
      text.force_encoding('UTF-8')
      text.each_line do |line|        
        if body.blank? 
          itext.write("body=#{line}")
          body = 1
        else
          itext.write("=#{line}")
        end
      end      
    else      
      logger "Path: #{path} should be deleted"
    end
    itext.close    
    logger "TEXT #{itext.path} generated"
    logger "Index command: #{$scriptindex} -s #{$user_stem_lang} #{databasepath} #{indexconf.path} #{itext.path}"    
    system_or_raise("#{$scriptindex} -s english #{databasepath} #{indexconf.path} #{itext.path}")
    itext.unlink    
    logger 'New doc added to xapian database'
  rescue Exception => e        
    logger e.message, true
  end
end

def logger(text, error = false)  
  if error
    $stderr.puts text
  elsif $verbose > 0    
    $stdout.puts text
  end  
end

def system_or_raise(command)
  if $verbose > 0
    raise "\"#{command}\" failed" unless system command
  else
    raise "\"#{command}\" failed" unless system command, :out => '/dev/null'
  end
end

def find_project(prt)        
  project = Project.active.has_module(:repository).find_by(identifier: prt)
  if project
    logger "Project found: #{project}"
  else
    logger "Project #{prt} not found", true
  end    
  @project = project
end

logger "Trying to load Redmine environment <<#{$environment}>>..."

begin
 require $environment
rescue LoadError
  logger "Redmine #{$environment} cannot be loaded!! Be sure the redmine installation directory is correct!", true
  logger "Edit script and correct path", true
  exit 1
end

logger "Redmine environment [RAILS_ENV=#{$env}] correctly loaded ..."

# Indexing files
unless $onlyrepos
  unless File.exist?($omindex)
    logger "#{$omindex} does not exist, exiting...", true
    exit 1
  end
  $stem_langs.each do | lang |
    filespath = File.join($redmine_root, $files)
    unless File.directory?(filespath)
      logger "An error while accessing #{filespath}, exiting...", true
      exit 1
    end
    databasepath = File.join($dbrootpath, lang)
    unless File.directory?(databasepath)
      logger "#{databasepath} does not exist, creating ..."
      begin
        FileUtils.mkdir_p databasepath
      rescue Exception => e
        logger e.message, true
        exit 1
      end      
    end
    cmd = "#{$omindex} -s #{lang} --db #{databasepath} #{filespath} --url / --depth-limit=0"
    cmd << ' -v' if $verbose > 0
    cmd << ' --retry-failed' if $retryfailed
    logger cmd    
    system_or_raise (cmd)
  end
  logger 'Redmine files indexed'
end

# Indexing repositories
unless $onlyfiles
  unless File.exist?($scriptindex)
    logger "#{$scriptindex} does not exist, exiting...", true
    exit 1
  end
  databasepath = File.join($dbrootpath.rstrip, 'repodb')  
  unless File.directory?(databasepath)
    logger "Db directory #{databasepath} does not exist, creating..."
    begin
      FileUtils.mkdir_p databasepath
    rescue Exception => e
      logger e.message, true
      exit 1
    end     
  end
  $projects = Project.active.has_module(:repository).pluck(:identifier) if $projects.blank?
  $projects.each do |identifier|
    project = Project.active.has_module(:repository).where(:identifier => identifier).preload(:repository).first
    if project
      logger "- Indexing repositories for #{project}..."
      repositories = project.repositories.select { |repository| repository.supports_cat? }
      repositories.each do |repository|
        delete_log(repository) if ($resetlog)
        indexing(databasepath, project, repository)
      end
    else
      logger "Project identifier #{identifier} not found or repository module not enabled, ignoring..."
    end
  end
end

exit 0