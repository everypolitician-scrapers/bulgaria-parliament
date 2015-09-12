#!/bin/env ruby
# encoding: utf-8

require 'scraperwiki'
require 'nokogiri'
require 'open-uri'
require 'colorize'

require 'pry'
require 'open-uri/cached'
OpenURI::Cache.cache_path = '.cache'

class String
  def tidy
    self.gsub(/[[:space:]]+/, ' ').strip
  end
end

def noko_for(url)
  Nokogiri::XML(open(url).read)
end

def date_from(str)
  return unless str
  Date.parse(str).to_s rescue nil
end

def overlap(mem, term)
  mS = mem[:start_date].to_s.empty?  ? '0000-00-00' : mem[:start_date]
  mE = mem[:end_date].to_s.empty?    ? '9999-99-99' : mem[:end_date]
  tS = term[:start_date].to_s.empty? ? '0000-00-00' : term[:start_date]
  tE = term[:end_date].to_s.empty?   ? '9999-99-99' : term[:end_date]

  return unless mS < tE && mE > tS
  (s, e) = [mS, mE, tS, tE].sort[1,2]
  return { 
    _data: [mem, term],
    start_date: s == '0000-00-00' ? nil : s,
    end_date:   e == '9999-99-99' ? nil : e,
  }
end

def combine(h)
  into_name, into_data, from_name, from_data = h.flatten
  from_data.product(into_data).map { |a,b| overlap(a,b) }.compact.map { |h|
    data = h.delete :_data
    h.merge({ from_name => data.first[:id], into_name => data.last[:id] })
  }.sort_by { |h| h[:start_date] }
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

def scrape_person(i)
  url = "http://www.parliament.bg/export.php/en/xml/MP/#{i}"
  noko = noko_for(url)
  return if noko.xpath("//schema/Profile/Names").size.zero?

  mems = noko.xpath('//ParliamentaryStructure[ParliamentaryStructureType[@value="Members of National Assembly"] and ParliamentaryStructurePosition[@value="Member"]]')
  return unless mems.count >= 1

  groups = noko.xpath('//ParliamentaryStructure[ParliamentaryStructureType[@value="Parliamentary Groups"]]')
  return unless groups.count >= 1

  first_name = noko.xpath('//Names/FirstName/@value').text
  sir_name = noko.xpath('//Names/FirstName/@value').text
  family_name = noko.xpath('//Names/FamilyName/@value').text
  area_id, area = noko.xpath('//Constituency/@value').text.split('-',2)

  person = { 
    id: i,
    name: "#{first_name} #{sir_name} #{family_name}".tidy,
    sort_name: "#{family_name}, #{first_name}".tidy,
    family_name: family_name,
    given_name: first_name,
    birth_date: date_from(noko.xpath('//DateOfBirth/@value').text),
    birth_place: noko.xpath('//PlaceOfBirth/@value').text.tidy,
    area: area,
    area_id: area_id,
    email: noko.xpath('//E-mail/@value').text,
    website: noko.xpath('//Website/@value').text,
    image: "http://www.parliament.bg/images/Assembly/#{i}.png",
  }

  group_mems = memberships_from(groups)
  term_mems = memberships_from(mems)
  combine(term: term_mems, party: group_mems).each do |t|
    data = person.merge(t)
    data[:party] = data[:party].sub('Parliamentary Group of ','').sub('Independent Members of Parliament', 'Independent') 
    data[:term] = data[:term][/^(\d+)/, 1] rescue binding.pry
    ScraperWiki.save_sqlite([:id, :term, :party, :start_date], data)
  end
end

(1..2650).each do |i|
  scrape_person(i)
end
