#!/bin/env ruby
# encoding: utf-8

require 'scraperwiki'
require 'nokogiri'
require 'open-uri'
require 'colorize'
require 'combine_popolo_memberships'

require 'pry'
require 'open-uri/cached'
OpenURI::Cache.cache_path = '.cache'

class String
  def tidy
    self.gsub(/[[:space:]]+/, ' ').strip
  end
end

def noko_for(url)
  raw = open(url).read.gsub(/Parliamentary Group\s+"(.*?)"/,'Parliamentary Group \1')
  Nokogiri::XML(raw)
end

def date_from(str)
  return unless str
  Date.parse(str).to_s rescue nil
end

def memberships_from(mems)
  mems.map { |pmem|
    {
      id: pmem.xpath('.//ParliamentaryStructureName/@value').text,
      start_date: pmem.xpath('.//ParliamentaryStructurePeriod/From/@value').text.split("/").reverse.join("-"),
      end_date: pmem.xpath('.//ParliamentaryStructurePeriod/To/@value').text.split("/").reverse.join("-"),
    }
  }.sort_by { |t| t[:start_date] }
end

def name_parts(noko,lang)
  first_name = noko.xpath('//Names/FirstName/@value').text
  sir_name = noko.xpath('//Names/SirName/@value').text
  family_name = noko.xpath('//Names/FamilyName/@value').text
  return { 
    "name__#{lang}".to_sym => "#{first_name} #{sir_name} #{family_name}".tidy,
    "sort_name__#{lang}".to_sym => "#{family_name} #{first_name}".tidy,
    "family_name__#{lang}".to_sym => family_name,
    "given_name__#{lang}".to_sym => first_name,
  }
end

def scrape_person(i)
  url_en = "http://www.parliament.bg/export.php/en/xml/MP/#{i}"
  url_bg = "http://www.parliament.bg/export.php/bg/xml/MP/#{i}"

  noko = noko_for(url_en)
  noko_bg = noko_for(url_bg)
  return if noko_bg.xpath("//schema/Profile/Names").size.zero?

  mems = noko.xpath('//ParliamentaryStructure[ParliamentaryStructureType[@value="Members of National Assembly"] and ParliamentaryStructurePosition[@value="Member"]]')
  return unless mems.count >= 1

  groups = noko.xpath('//ParliamentaryStructure[ParliamentaryStructureType[@value="Parliamentary Groups"]]')
  return unless groups.count >= 1

  name_en = name_parts(noko, 'en')
  name_bg = name_parts(noko_bg, 'bg')

  area_id, area = noko.xpath('//Constituency/@value').text.split('-',2)

  person = { 
    id: i,
    birth_date: date_from(noko.xpath('//DateOfBirth/@value').text),
    birth_place: noko.xpath('//PlaceOfBirth/@value').text.tidy,
    area: area,
    area_id: area_id,
    email: noko.xpath('//E-mail/@value').text,
    website: noko.xpath('//Website/@value').text,
    image: "http://www.parliament.bg/images/Assembly/#{i}.png",
    source: url_bg,
  }.merge(name_en).merge(name_bg)
  person[:name] = [person["name__en"], person["name__bg"]].find { |n| !n.to_s.empty? }

  group_mems = memberships_from(groups)
  term_mems = memberships_from(mems)
  combos = CombinePopoloMemberships.combine(term: term_mems, party: group_mems)
  combos.each do |t|
    data = person.merge(t)
    data[:party] = data[:party].sub('Parliamentary Group of ','').sub('Independent Members of Parliament', 'Independent') 
    data[:term] = data[:term][/^(\d+)/, 1] rescue binding.pry
    ScraperWiki.save_sqlite([:id, :term, :party, :start_date], data)
  end
end

# rows = ScraperWiki.select("DISTINCT(id) from 'data' WHERE party LIKE 'Parliamentary Group%'")
# rows.map { |r| r['id'] }.each do |i|
(1..2650).each do |i|
  warn i if (i % 50).zero?
  ScraperWiki.sqliteexecute('DELETE FROM data WHERE id = ?', i)
  scrape_person(i)
end
