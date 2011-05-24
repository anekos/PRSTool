#!/usr/bin/ruby
# vim: set fileencoding=utf-8 :
# vim: set foldmethod=syntax :

require 'rexml/document'
require 'fileutils'
require 'find'
require 'pathname'
require 'date'

def phase (msg)
  puts("<#{msg}>")
end

def result (msg)
  puts("  #{msg}")
end

def block (msg)
  phase(msg)
  yield
end

def find (path, &block)
  Find.find(path.to_s) do
    |it|
    if Encoding::Windows_31J == it.encoding and /cygwin\Z/ === RUBY_PLATFORM
      it.force_encoding("UTF-8")
    end
    block.call(it)
  end
end

def P (path)
  Pathname.new(path)
end

class Pathname
  def child? (base)
    not /\A\.\.(\Z|\/|\\)/ === self.relative_path_from(base).to_s
  end
end

class TextEntry
  def self.author_and_title_from_path (path)
    _, author, title = *path.to_s.match(/\A\[([^\]]+)\]\s*(.+)\Z/)
    author && title && [author, title]
  end

  def initialize (name, path, real_path)
    @name, @path, @real_path = name, path, real_path
    @author, @title = *TextEntry.author_and_title_from_path(path)
  end

  def to_xml (id = 666_666)
    elem = REXML::Element.new(@name)
    {
      #:source_id => source_id,
      :id => id,
      :author => @author,
      :path => @path,
      :title => @title,
      :date => File.mtime(@real_path).strftime('%a, %d %b %Y %H:%M:%S UTC'),
      :mime => mime,
      :size => File.size(@real_path)
    }.each {|k, v| elem.attributes[k.to_s] = v.to_s }
    elem
  end

  private

  def mime
    case @path.to_s.gsub(/[^\.]*\./, '').downcase
    when 'pdf'
      'application/pdf'
    when 'lrf'
      'application/x-sony-bbeb'
    when 'epub'
      'application/epub+zip'
    else
      raise 'Unknown File Type'
    end
  end
end

class Fixer
  def self.backup_file (path)
    FileUtils.mv(path, path.sub(/\.\w+\Z/, '.unk'))
  end

  def self.execute (body, ms, sd, dest, sync_from, op)
    max_id = nil
    [[:body, body], [:ms, ms], [:sd, sd]].each do
      |drive, drive_path|
      fixer = Fixer.new(drive, drive_path, dest, sync_from, max_id)
      fixer.execute(op.include?(drive) ? op : [])
      max_id = fixer.last_id
    end
    puts(max_id)
  end

  #############################################################################

  attr_reader :main_xml_path, :ext_xml_path

  def initialize (drive, drive_path, dest, sync_from, max_id = nil)
    @drive = drive
    @drive_path, @dest, @sync_from = *[drive_path, dest, sync_from].map {|it| it && P(it) }
    @max_id = max_id
    @last_id = nil

    @main_xml_path, @ext_xml_path =
      if drive == :body
        ['media.xml', 'cacheExt.xml'].map {|it| @drive_path + P('database/cache') + P(it) }
      else
        ['cache.xml', 'cacheExt.xml'].map {|it| @drive_path + P('Sony Reader/database') + P(it) }
      end
  end

  def execute (op)
    phase("#{@drive} の処理開始")
    xml = REXML::Document.new(File.read(@main_xml_path))
    sync_files(xml, false)
    sync_items(xml) if op.include?(:synchronize)
    fix_title_author(xml) if op.include?(:title)
    sort_items(xml) if op.include?(:sort)
    remove_playlists(xml)
    reset_ids(xml)
    make_playlists(xml) if op.include?(:playlist)
    save_xml(xml) if op.include?(:save)
  end

  def last_id
    if @last_id
      @last_id
    else
      xml = REXML::Document.new(File.read(@main_xml_path))
      get_ids(xml).last
    end
  end

  private

  def sync_files (xml, real)
    phase 'ファイルの同期'

    exists = {}
    xml.elements.each(xpath('/xdbLite/records/cache:text', '/cache/text')) do
      |elem|
      exists[P(elem.attributes['path']).cleanpath] = elem
    end

    sync_count = 0
    src = @sync_from + @drive.to_s
    find(src) do
      |filepath|
      next unless File.file?(filepath)
      dest = @drive_path + @dest + P(filepath).relative_path_from(src)
      name = (@dest + P(filepath).relative_path_from(src)).cleanpath
      elem = exists[name]
      fsize = File.size(filepath)
      next if real ? dest.exist? && fsize == dest.size
                   : elem && fsize == elem.attributes['size'].to_i
      result name
      FileUtils.cp(filepath, dest)
      sync_count += 1
    end

    result "#{sync_count} items"
  end

  def sync_items (xml)
    change = scan_item_changes(xml)

    block '新規アイテム追加' do
      change.added.each do
        |item|
        elem = TextEntry.new(xpath('cache:text', 'text'), @dest + item, @drive_path + @dest + item).to_xml
        xml.elements[xpath('/xdbLite/records', '/cache')].add(elem)
      end
      result "#{change.added.size} items"
    end

    block '消去されたアイテム削除' do
      change.removed.each do
        |item|
        xml.elements[xpath('/xdbLite/records', '/cache')].each_element_with_attribute('path', item.to_s) do
          |e|
          e.parent.delete(e)
        end
      end
      result "#{change.removed.size} items"
    end
  end

  def fix_title_author (xml)
    phase 'タイトルと著者名の修正'

    xml.elements.each(xpath('/xdbLite/records/cache:text', '/cache/text')) do
      |elem|
      next unless name = File.basename(elem.attributes['path'])
      author, title = *TextEntry.author_and_title_from_path(name)
      next unless author and title
      title.sub!(/\.\w{3,4}\Z/, '')
      elem.attributes['author'] = author
      elem.attributes['title'] = title
    end
  end

  def sort_items (xml)
    phase '著者名/タイトルでソート'

    date = Date.new(2000, 1, 1)

    items =
      xml.elements.to_a(xpath('/xdbLite/records/cache:text', '/cache/text')).sort_by do
        |elem|
        "#{elem.attributes['author']}/#{elem.attributes['title']}"
      end

    xml.elements.delete_all(xpath('/xdbLite/records/cache:text', '/cache/text'))
    cache_node = xml.elements[xpath('/xdbLite/records', '/cache')]
    items.each {|elem| cache_node.add(elem) }
  end

  def remove_playlists (xml)
    xml.elements.delete_all(
      xpath(
        '/xdbLite/records/cache:playlist[not(@uuid)]',
        '/cache/playlist[not(@uuid)]'
      )
    )
  end

  def reset_ids (xml)
    id_map = {}

    source_id = nil

    block 'ID振りなおし' do
      if @drive === :body
        base, source_id = 0, 1, 0
      else
        source_id = @max_id + 1
        base = @max_id + 2
      end

      id = base
      xml.elements.each("#{xpath('/xdbLite/records', '/cache')}/[@id]") do
        |elem|
        id_map[elem.attributes['id']] = id
        elem.attributes['id'] = id.to_s
        @last_id = id
        id += 1
      end

      result "sourceid = #{source_id}, lastid = #{@last_id}"
    end

    @source_id = source_id

    block 'プレイリスト内ID修正' do
      xml.elements.each(xpath('/xdbLite/records/cache:playlist/cache:item', '/cache/playlist/item')) do
        |elem|
        old_id = elem.attributes['id']
        new_id = id_map[old_id]
        raise "Not found new ID: #{old_id}" unless new_id and old_id
        elem.attributes['id'] = new_id.to_s
      end
    end

  end

  def make_playlists (xml)
    return unless @last_id and @source_id

    phase 'プレイリスト作成'

    playlist_id, source_id = @last_id, @source_id

    list_names = {}
    xml.elements.each(xpath('/xdbLite/records/cache:text', '/cache/text')) do
      |elem|
      next unless path = elem.attributes['path'] and id = elem.attributes['id']
      next unless P(path).parent.child?(@dest)
      name = P(path).parent.relative_path_from(@dest).to_s
      puts(".. = #{path}") if /\.\.\/light/ === name
      (list_names[name] ||= []) << id
    end
    cache_node = xml.elements[xpath('/xdbLite/records', '/cache')]
    list_names.keys.sort.each do
      |name|
      item_ids = list_names[name]
      list_node = REXML::Element.new(xpath('cache:playlist', 'playlist'))
      list_node.add_attributes(
        'title' => name,
        'sourceid' => source_id.to_s,
        'id' => playlist_id.to_s
      )
      item_ids.each do
        |id|
        item_node = REXML::Element.new('item')
        item_node.add_attributes('id' => id.to_s)
        list_node.add(item_node)
      end
      cache_node.add(list_node)

      @last_id = playlist_id
      playlist_id += 1

      result name
    end
  end

  def save_xml (xml)
    phase 'XMLファイルに書き出し'

    Fixer.backup_file(@main_xml_path)
    File.open(@main_xml_path, 'w') do
      |file|
      formatter = REXML::Formatters::Pretty.new
      formatter.write(xml, file)
    end
  end

  ########################################

  def scan_item_changes (xml)
    dest_items = {}
    block 'キャッシュ上のファイルを取得' do
      xml.elements.each(xpath('/xdbLite/records/cache:text', '/cache/text')) do
        |elem|
        next unless path_attr = elem.attributes['path']
        item = P(path_attr).cleanpath
        next unless item.child?(@dest)
        dest_items[item] = 1
      end
      result "#{dest_items.keys.size} items"
    end

    added_items = []
    found_items = {}
    block '新しいファイルを検索' do
      find(@drive_path + @dest) do
        |path|
        next unless File.file?(path)
        item = P(path).relative_path_from(@drive_path).cleanpath
        found_items[item] = true
        added_items << item.relative_path_from(@dest) unless dest_items[item]
      end
      result "#{added_items.size} items"
    end

    removed_items = []
    block '削除されたファイルを取得' do
      xml.elements.each(xpath('/xdbLite/records/cache:text', '/cache/text')) do
        |elem|
        next unless path_attr = elem.attributes['path']
        item = P(path_attr).cleanpath
        next unless item.child?(@dest)
        removed_items << item unless found_items[item]
      end
      result "#{removed_items.size} items"
    end

    Struct.new(:added, :removed).new(added_items, removed_items)
  end

  def get_ids (xml)
    ids = []

    xml.elements.each('//[@id]') do
      |elem|
      next unless id = elem.attributes['id']
      ids << id.to_i
    end

    ids.sort!
    ids.uniq!

    spaces = []
    prev = ids.first
    ids[1..-1].each do
      |id|
      spaces << (prev + 1 .. id - 1) unless id == prev + 1
      prev = id
    end if ids.size > 1

    Struct.new(:first, :last).new(ids.first, ids.last)
  end

  def xpath (body, media)
    case @drive
    when :body
      body
    when :ms, :sd
      media
    else
      raise "Unknown drive: #{drive}"
    end
  end
end


class OptionParser
  def self.parse (args)
    require 'ostruct'
    require 'optparse'

    op = OpenStruct.new

    parser = OptionParser.new do
      |parser|
      parser.banner = "Usage: #{File.basename($0)} [options]"

      parser.on('--body <BODY_DRIVE_PATH>') { |it| op.body = it }
      parser.on('--ms <MS_DRIVE_PATH>') { |it| op.ms = it }
      parser.on('--sd <SD_DRIVE_PATH>') { |it| op.sd = it }
      parser.on('--root <MEDIA_ROOT>') { |it| op.root = it }
      parser.on('--sync <SYNC_FROM_PATH>') { |it| op.sync = it }
    end

    parser.parse!(args)

    raise 'Please give all _PATH/ROOT options.' unless op.body and op.ms and op.sd and op.root

    op
  rescue => e
    puts e
    puts parser.help
    exit
  end
end

Options = OptionParser.parse(ARGV)

Fixer.execute(
  Options.body, Options.ms, Options.sd, Options.root, Options.sync,
  [:synchronize, :title, :playlist, :sort, :save, :body, :ms, :sd]
)
