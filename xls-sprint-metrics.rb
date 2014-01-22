#
# Barry Mullan (c) Rally Software
#
# May 2013 - Extract certain sprint metrics to an xls file
#
# to run use ...
# ruby xls-sprint-metrics.rb config.json <password>
#

require 'rally_api'
require 'logger'
require 'net/http'
require 'uri'
require 'time'
require 'date'
require 'csv'
require 'pp'
require 'axlsx'
require 'tzinfo'

metric_labels = ["Committed (Count)","Final (Count)","Accepted (Count)","Carried Over (Count)","Committed (Points)","Final (Points)","Accepted (Points)","Carried Over (Points)","No Estimate (Percentage)","50% Accepted(Percentage)","Points Accepted (Percentage)","Points Not Completed (Percentage)","Daily In-Progress (Percentage)","Task Estimate First Day (Hours)","Task Estimate Last Day (Hours)","Task Actual Last Day (Hours)"]

module RallyAPI
	class RallyObject
		attr_accessor :offspring
	end
end

module Enumerable 
  def pluck(method, *args) 
    map { |x| x.send method, *args } 
  end 
   
  alias invoke pluck 
end 
 
class Array 
  def pluck!(method, *args) 
    each_index { |x| self[x] = self[x].send method, *args } 
  end 
   
  alias invoke! pluck! 
end

# wrapper class that manages both Rally rest_api and Rally "lbapi" calls
class LookBackData

	# def initialize(workspace,project)
	def	initialize(url,username,password,workspace_name,project_name,log_file,projects)

		@log = Logger.new( log_file , 'daily' )

		@headers = RallyAPI::CustomHttpHeader.new()
		@headers.name = "LookBackData"
		@headers.vendor = "Rally"
		@headers.version = "1.0"

		@config = {:base_url => url} # "https://rally1.rallydev.com/slm"}
		@config[:username]   = username # "xxxbmullan@emc.com"
		@config[:password]   = password
		@config[:workspace]  = workspace_name
		@config[:version]    = "1.40"
		@config[:project]    = @project_name
		@config[:headers]    = @headers #from RallyAPI::CustomHttpHeader.new()

		@rally = RallyAPI::RallyRestJson.new(@config)

		@workspace = find_object(:workspace,workspace_name)
		@log.debug(@workspace)
		@project = find_object(:project,project_name)
		@log.debug(@project)
		@username = username
		@password = password
		@projects = projects

	end

	def get_project_id
		@project.ObjectID
	end

	def get_project_parent_name
		@project.Parent ? @project.Parent.Name : ""
	end

	def create_releases_query
		iteration_query = RallyAPI::RallyQuery.new()
		iteration_query.type = :release
		iteration_query.workspace = @workspace
		iteration_query.project = @project
		iteration_query.fetch = "ObjectID,ReleaseStartDate,ReleaseDate,Name,PlannedVelocity,Project"
		iteration_query.project_scope_up = false
		iteration_query.project_scope_down = true
		iteration_query.order = "ObjectID"
		iteration_query.query_string = ""
		iteration_query
	end

	def create_iterations_query
		iteration_query = RallyAPI::RallyQuery.new()
		iteration_query.type = :iteration
		iteration_query.workspace = @workspace
		iteration_query.project = @project
		iteration_query.fetch = "ObjectID,StartDate,EndDate,Name,PlannedVelocity,Project"
		iteration_query.project_scope_up = false
		iteration_query.project_scope_down = true
		iteration_query.order = "EndDate"
		iteration_query.query_string = ""
		iteration_query
	end

	def get_date_array start_date, end_date
		#pp end_date
		# d1 = Date.parse(start_date)
		# d2 = Date.parse(end_date) 

		dates = (start_date .. end_date).to_a

		# knockout weekend days.
		dates.delete_if { |d| d.strftime("%A") == "Sunday" || d.strftime("%A") == "Saturday" }
		return dates
	end

	def get_releases_by_id project_id
		query = create_releases_query()
		query.query_string = "(Project.ObjectID = #{project_id})"
		results = @rally.find(query)
		rally_results_to_array(results)
	end

	def get_releases_by_name name
		query = create_releases_query()
		query.query_string = "(Name = \"#{name}\")"
		
		results = @rally.find(query)
		rally_results_to_array(results)
	end

	def get_previous_iterations 
		query = create_iterations_query()
		#query.query_string = "((EndDate < \"#{Time.now.utc.iso8601}\") and (Project = \"#{@project["_ref"]}\"))"
		query.query_string = "((StartDate < \"#{Time.now.utc.iso8601}\") and (Project = \"#{@project["_ref"]}\"))"
		#print query.query_string,"\n"
		results = @rally.find(query)
		rally_results_to_array(results)
	end

	def get_projects 
		query = create_projects_query()
		results = @rally.find(query)
		results
	end

	# "unboxes" the Rally results object into a plain ruby array
	def rally_results_to_array(results)
		arr = []
		results.each { |result|
			arr.push(result)
		}
		arr
	end

	# returns true if the specified day occurs within the snapshot valid from and to dates.
	def day_in_snapshot snapshot,day

		#tz.utc_to_local(Time.parse(start_date)) 
		#vf = @tz.utc_to_local(Time.parse(snapshot["_ValidFrom"]))
		#dvf = Date.parse(vf.to_s)

		if snapshot["_ValidTo"][0..3] == "9999"
			if day >= Date.parse(snapshot["_ValidFrom"])
			#if day >= dvf
				return true
			end
		end

		return day < Date.parse(snapshot["_ValidTo"]) && day >= Date.parse(snapshot["_ValidFrom"])

	end

	def find_object(type,name)
		object_query = RallyAPI::RallyQuery.new()
		object_query.type = type
		object_query.fetch = "Name,ObjectID,FormattedID,Parent"
		object_query.project_scope_up = false
		object_query.project_scope_down = true
		object_query.order = "Name Asc"
		object_query.query_string = "(Name = \"" + name + "\")"
		results = @rally.find(object_query)
		results.each do |obj|
			return obj if (obj.Name.eql?(name))
		end
		nil
	end

	def lookback_query(body)
		json_url = "https://rally1.rallydev.com/analytics/v2.0/service/rally/workspace/#{@workspace.ObjectID}/artifact/snapshot/query.js"
		@log.debug(json_url)
		uri = URI.parse(json_url)
		http = Net::HTTP.new(uri.host, uri.port)
		http.use_ssl = true
		http.verify_mode = OpenSSL::SSL::VERIFY_NONE
		request = Net::HTTP::Post.new(uri.request_uri,initheader = {'Content-Type' =>'application/json'})
		@log.info(body.to_json)
		request.body = body.to_json
		@log.debug(request.body)
		request.basic_auth @username, @password
		response = http.request(request)
		@log.debug(response.code)
		#print "Response Code:'#{response.code}', #{response.code.to_i==200}\n"
		if response.code.to_i == 200
			response.body	
		else
			@log.debug("Response Code:#{response.code}")
			nil
		end
	end

	# the following methods are sample "lbapi" queries. "lbapi" queries are based on 
	# mongodb query syntax. For more information see this link ...
	# http://docs.mongodb.org/manual/core/read/#crud-read-find

	def query_hierarchy(parent_object_id)

		body = { "find" => { "_ItemHierarchy" => parent_object_id},
				 "fields" => ["ObjectID","Name","_UnformattedID","_SnapshotNumber","ScheduleState",
				 			  "State","_ValidFrom","_ValidTo","Project","Children","Tasks"],
				 "hydrate" => ["ScheduleState","State"]
		}
		return lookback_query(body)
	end

	def query_type(parent_object_id)

		body = { "find" => { "_TypeHierarchy" => parent_object_id},
				 "fields" => true,
				 "hydrate" => ["ScheduleState","State"]
		}
		return lookback_query(body)
	end

	def query_snapshots_for_objects(obj_array)

		body = { 
			"find" => {"ObjectID" => { "$in" => obj_array} },
			"fields" => ["ObjectID","FormattedID","Name","Parent","Release","Project","Tags","PlanEstimate","ScheduleState","_ValidFrom","_ValidTo","Iteration"],
			"hydrate" => ["ScheduleState"]
		}
		return lookback_query(body)

	end

	def query_snapshots_for_releases(release_ids)

		body = { 
			"find" => {"Release" => { "$in" => release_ids } , "_TypeHierarchy" => "Defect" },
			"fields" => ["ObjectID","FormattedID","Name","Release","Project","State","Severity","Priority","Tags","PlanEstimate","_ValidFrom","_ValidTo"],
			"hydrate" => ["State","Priority","Severity","Tags"]
		}
		return lookback_query(body)
	end

	def cache(filename)
		file = File.open(filename, "rb")
		contents = file.read
		file.close
		contents
	end

	def cached(filename)
		return File.exists?(filename)
	end

	def cache_filename(iterations)
		"./cache/" + (((iterations.map { |it| it["ObjectID"] }).join("-"))+".json")
	end

	def carried_over_filename(iteration1,iteration2)
		"./cache/" + iteration1["ObjectID"].to_s + "-" + iteration2["ObjectID"].to_s + ".json"
	end

	def save_to_cache(content,filename)

		File.open( filename,'w') { |f| f.write(content) }

		content

	end

	# returns snapshots for stories carried over from 1 to 2
	def query_snapshots_for_carried_over(iteration1,iteration2)

		filename = carried_over_filename(iteration1,iteration2)

		return cache( filename ) if cached( filename )

		body = { 
			"find" => {"Iteration" => iteration2["ObjectID"] , "_TypeHierarchy" => { "$in" => ["Defect","HierarchicalRequirement"]},
				"_PreviousValues.Iteration" => iteration1["ObjectID"]
			},
			"fields" => ["ObjectID","FormattedID","Name","Iteration","Release","Project","ScheduleState","Severity","Priority","Tags","PlanEstimate","_ValidFrom","_ValidTo"],
			"hydrate" => ["ScheduleState","Priority","Severity","Tags"],
			"pagesize" => 10000
		}

		return save_to_cache(lookback_query(body), filename )

	end

	def query_snapshots_for_iterations(iterations)

		if cached(cache_filename(iterations))
			return cache(cache_filename(iterations))
		end

		body = { 
			"find" => {"Iteration" => { "$in" => iterations.map {|it| it["ObjectID"]}} , "_TypeHierarchy" => { "$in" => ["Defect","HierarchicalRequirement"]}},
			"fields" => ["_UnformattedID", "ObjectID","FormattedID","Name","Iteration","Release","Project","ScheduleState","Severity","Priority","Tags","PlanEstimate","_ValidFrom","_ValidTo","TaskEstimateTotal","TaskActualTotal"],
			"hydrate" => ["ScheduleState","Priority","Severity","Tags"],
			"pagesize" => 10000
		}

		return save_to_cache(lookback_query(body),cache_filename(iterations))

	end

	def findProject( current, name)
		#print "returning ",current["ObjectID"],"\n"
		r =  current if current["Name"] == name
		if current["childs"]
			current["childs"].each { |child|
				r = findProject(child,name) if !r
			}
		end
		r
	end

	def iteration_start_date(iteration)
		return Date.parse(iteration.StartDate) + @iteration_start_day
	end

	def metric_day1_task_estimate_total(iteration,dates,snapshots)
		#d = Date.parse(iteration.StartDate) + 1
		d = iteration_start_date(iteration)
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,d)}).compact!

		day1_total = 0

		if sfd1
			day1_total = sfd1.length > 0 ? 
				((sfd1.map { |sn| sn["TaskEstimateTotal"] ? sn["TaskEstimateTotal"] : 0})).reduce(0,:+) : 0
		end
		
		return day1_total
	end

	def metric_day2_task_estimate_total(iteration,dates,snapshots)
		d = Date.parse(iteration.EndDate) + 1
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,d)}).compact!
		#print "snapshots:#{sfd1.length}\n"
		day2_total = 0

		if sfd1
			day2_total = sfd1.length > 0 ? 
				((sfd1.map { |sn| sn["TaskEstimateTotal"] ? sn["TaskEstimateTotal"] : 0})).reduce(0,:+) : 0
		end
		
		return day2_total
	end

	def metric_day2_task_actual_total(iteration,dates,snapshots)
		d = Date.parse(iteration.EndDate) + 1
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,d)}).compact!
		#print "snapshots:#{sfd1.length}\n"
		day2_total = 0

		if sfd1
			day2_total = sfd1.length > 0 ? 
				((sfd1.map { |sn| sn["TaskActualTotal"] ? sn["TaskActualTotal"] : 0})).reduce(0,:+) : 0
		end
		
		return day2_total
	end


	def metric_day1_committed_count(iteration,dates,snapshots)
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,dates.first)}).compact!
		day1_count = 0
		if sfd1
			day1_count = sfd1.length > 0 ? 
				((sfd1.map { |sn| 1 })).reduce(0,:+) : 0
		end
		
		return day1_count
	end

	def metric_day2_committed_count(iteration,dates,snapshots)
		#pp dates.last
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,dates.last)}).compact!
		day1_count = 0
		if sfd1
			day1_count = sfd1.length > 0 ? 
				((sfd1.map { |sn| 1 })).reduce(0,:+) : 0
		end
		return day1_count
	end
	def metric_day2_accepted_count(iteration,dates,snapshots)
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,dates.last)}).compact!
		accepted = 0
		if sfd1
			accepted = sfd1.length > 0 ? 
				((sfd1.map { |sn| sn["ScheduleState"]== "Accepted" ? 1 : 0 })).reduce(0,:+) : 0
		end
		return accepted
	end


	def metric_day1_committed_points(iteration,dates,snapshots)
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,dates.first)}).compact!

		day1_points = 0

		if sfd1
			day1_points = sfd1.length > 0 ? 
				((sfd1.map { |sn| sn["PlanEstimate"] ? sn["PlanEstimate"] : 0})).reduce(0,:+) : 0
		end
		
		return day1_points
	end

	def metric_day2_committed_points(iteration,dates,snapshots)

		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,dates.last)}).compact!

		day1_points = 0

		if sfd1
			day1_points = sfd1.length > 0 ? 
				((sfd1.map { |sn| sn["PlanEstimate"] ? sn["PlanEstimate"] : 0})).reduce(0,:+) : 0
		end
		
		return day1_points
	end

	def metric_day2_accepted_points(iteration,dates,snapshots)

		d = Date.parse(iteration.EndDate)

		#sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,dates.last)}).compact!
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,d)}).compact!

		accepted = 0

		if sfd1
			accepted = sfd1.length > 0 ? 
				((sfd1.map { |sn| 
					#print sn["_UnformattedID"],"\t",sn["PlanEstimate"],"\n" if sn["ScheduleState"] == "Accepted"
					sn["ScheduleState"]== "Accepted" ? (sn["PlanEstimate"] ? sn["PlanEstimate"] : 0) : 0

					})).reduce(0,:+) : 0
		end
		
		return accepted
	end

	def metric_carried_over(iteration1,iteration2,type)

		return 0 if !iteration2

		snapshots = (JSON.parse( query_snapshots_for_carried_over(iteration1,iteration2)))["Results"]

		# snapshots = snapshots.map { |snapshot| snapshot["ObjectID"] } .uniq

		return ( type == "count" ? 
			snapshots.length : 
			snapshots.length > 0 ? (snapshots.map { |sn| sn["PlanEstimate"] ? sn["PlanEstimate"].to_f : 0 }).reduce(0,:+) : 0)

	end

	# count the number of items that dont have an estimate on day 1 of the iteration
	def metric_day1_no_estimates(iteration,dates,snapshots)
		#sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,dates.first)}).compact!
		#d = Date.parse(iteration.StartDate) + 1
		d = iteration_start_date(iteration)
		sfd1 = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,d)}).compact!

		day1_no_estimate = 0
		day1_count = 0

		if sfd1
			day1_no_estimate = sfd1.length > 0 ? 
				((sfd1.map { |sn| !sn["PlanEstimate"] || sn["PlanEstimate"] == 0 ? 1 : 0})).reduce(0,:+) : 0
			day1_count = sfd1.length > 0 ? 
				((sfd1.map { |sn| 1 })).reduce(0,:+) : 0

		end
		
		#return day1_no_estimate > 0 ? ((day1_no_estimate/day1_count)*100) : 0
		return day1_no_estimate > 0 ? ((day1_no_estimate.to_f/day1_count.to_f)*100).to_i : 0
	end

	def metric_50_percent_accepted(iteration,date_array,snapshots)

		date_array.each_with_index { |day,i| 
			# filter to just the snapshots for that day
			sfd = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,day)}).compact!
			if sfd
				accepted = sfd.length > 0 ? 
				((sfd.map { |sn| sn["ScheduleState"]== "Accepted" ? 1 : 0})).reduce(0,:+) : 0
				count = (sfd.map { |snapshot| snapshot["ObjectID"] }).uniq.length
				#print "Count:#{count} Accepted:#{accepted} %#{((accepted.to_f/count.to_f)*100)}\n"
				if count > 0 and (( accepted.to_f / count.to_f ) * 100) >= 50
					pInIteration = (( i.to_f / date_array.length.to_f) * 100)
					return (pInIteration.to_i)
				end
			end
		}
		return 0

	end

	def metric_points_accepted_percentage(metrics)
		
		final_points = metrics['Final (Points)']
		accepted_points = metrics['Accepted (Points)']

		pAccepted = final_points > 0 ? (accepted_points.to_f / final_points.to_f) * 100 : 0
		return pAccepted.to_i

	end

	
	# returns the % of points not completed (or accepted)
	def metric_points_not_completed_percentage(iteration,date_array,snapshots)

		sfd = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,date_array.last)}).compact!

		total_points = 0
		not_completed_points = 0

		if sfd
			total_points = sfd.length > 0 ? 
				((sfd.map { |sn| !sn["PlanEstimate"] || sn["PlanEstimate"] == 0 ? 0 : sn["PlanEstimate"] })).reduce(0,:+) : 0
			not_completed_points = sfd.length > 0 ? 
				((sfd.map { |sn| !sn["PlanEstimate"] || sn["PlanEstimate"] == 0 || sn["ScheduleState"] == "Accepted" || sn["ScheduleState"] == "Completed" ? 0 : sn["PlanEstimate"] })).reduce(0,:+) : 0

		end
		
		return total_points > 0 ? ((not_completed_points.to_f/total_points.to_f)*100).to_i : 0

	end

	# returns an average of how much work in progress daily
	def metric_points_in_progress_percentage(iteration,date_array,snapshots)

		daily_pcs = []
		date_array.each_with_index { |day,i| 
			# filter to just the snapshots for that day
			sfd = (snapshots.collect { |snapshot| snapshot if day_in_snapshot(snapshot,day)}).compact!
			if sfd
				#inp = sfd.length > 0 ? 
				#((sfd.map { |sn| sn["ScheduleState"]== "In-Progress" ? 1 : 0})).reduce(0,:+) : 0
				# should be based on points.
				inp = sfd.length > 0 ? 
				((sfd.map { |sn| sn["ScheduleState"]== "In-Progress" ? ( !sn["PlanEstimate"] || sn["PlanEstimate"] == 0 ? 0 : sn["PlanEstimate"]) : 0})).reduce(0,:+) : 0
				total = sfd.length > 0 ? 
				((sfd.map { |sn| ( !sn["PlanEstimate"] || sn["PlanEstimate"] == 0 ? 0 : sn["PlanEstimate"]) })).reduce(0,:+) : 0

				#count = (sfd.map { |snapshot| snapshot["ObjectID"] }).uniq.length
				#print "Count:#{count} Accepted:#{accepted} %#{((accepted.to_f/count.to_f)*100)}\n"
				daily_pcs.push( total > 0 ? ((inp.to_f / total.to_f) * 100).to_i : 0 )
			end
		}

		avg = (daily_pcs.inject{ |sum, el| sum + el }.to_f / daily_pcs.size)
		return avg > 0 ? avg.to_i : 0


	end


	def populate_metrics(project,iterations,labels, iteration_start_day)

		@iteration_start_day = iteration_start_day
		
		allMetrics = {}

		iterations.each_with_index { |iteration, i|
			print "#{project}:#{iteration["Name"]}\n"

			snapshots = (JSON.parse(query_snapshots_for_iterations([iteration]))) ["Results"]

			#print "iteration snapshots:#{snapshots.length}\n"

			#date_array = get_date_array( iteration.StartDate, iteration.EndDate )
			date_array = get_date_array( Date.parse(iteration.StartDate) + (@iteration_start_day-1), Date.parse(iteration.EndDate) )

			metrics = {}

			# metric_labels = ["Committed (Count)","Final (Count)","Accepted (Count)",
			# "Carried Over (Count)","Committed (Points)","Final (Points)","Accepted (Points)","Carried Over (Points)",
			# "No Estimate (Percentage)","50% Accepted(Percentage)"]

			labels.each { |label|
				case label
					when 'Committed (Count)'
						metrics[label] = metric_day1_committed_count(iteration,date_array,snapshots)
					when 'Final (Count)'
						metrics[label] = metric_day2_committed_count(iteration,date_array,snapshots)
					when 'Accepted (Count)'
						metrics[label] = metric_day2_accepted_count(iteration,date_array,snapshots)
					when 'Carried Over (Count)'
						metrics[label] = metric_carried_over( iteration, ( i < iterations.length - 1 ? iterations[i+1] : nil),"count")
					when 'Committed (Points)'
						metrics[label] = metric_day1_committed_points(iteration,date_array,snapshots)
					when 'Final (Points)'
						metrics[label] = metric_day2_committed_points(iteration,date_array,snapshots)
					when 'Accepted (Points)'
						metrics[label] = metric_day2_accepted_points(iteration,date_array,snapshots)
					when 'Carried Over (Points)'
						metrics[label] = metric_carried_over( iteration, ( i < iterations.length - 1 ? iterations[i+1] : nil),"points")
					when 'No Estimate (Percentage)'
						metrics[label] = metric_day1_no_estimates(iteration,date_array,snapshots)
					when '50% Accepted(Percentage)'
						metrics[label] = metric_50_percent_accepted(iteration,date_array,snapshots)
					when 'Points Accepted (Percentage)'
						metrics[label] = metric_points_accepted_percentage(metrics)
					when 'Points Not Completed (Percentage)'
						metrics[label] = metric_points_not_completed_percentage(iteration,date_array,snapshots)
					when 'Daily In-Progress (Percentage)'
						metrics[label] = metric_points_in_progress_percentage(iteration,date_array,snapshots)
					when "Task Estimate First Day (Hours)"
						metrics[label] = metric_day1_task_estimate_total(iteration,date_array,snapshots)
					when "Task Estimate Last Day (Hours)"
						metrics[label] = metric_day2_task_estimate_total(iteration,date_array,snapshots)
					when "Task Actual Last Day (Hours)"
						metrics[label] = metric_day2_task_actual_total(iteration,date_array,snapshots)
				end
			}
			allMetrics[iteration["ObjectID"].to_s] = metrics
		}
		allMetrics
	end
end

class XLS

	def	initialize(project_names,project_iterations,project_metrics,labels,iteration_start_day)

		@projects = project_names
		@iterations = project_iterations
		@metrics = project_metrics
		@metrics_labels = labels
		@tz = TZInfo::Timezone.get('America/New_York')
		@iteration_start_day = iteration_start_day ? iteration_start_day : 1

	end

	def iteration_end_date(iteration) 
		t1 = @tz.utc_to_local(Time.parse(iteration["EndDate"])) 
		d1 = Date.new(t1.year,t1.mon,t1.day)
		d1.strftime("%-m/%d")
	end

	def iteration_start_date(iteration) 
		t1 = @tz.utc_to_local(Time.parse(iteration["StartDate"])) 
		d1 = Date.new(t1.year,t1.mon,t1.day)
		d1.strftime("%-m/%d")
	end


	def write_to_file filename

		dataSheet = nil
		project_rows = {}

		# style to rotate text
		Axlsx::Package.new do |p|

			p.use_autowidth = false
			cell_rotated_text_style = p.workbook.styles.add_style(:alignment => {:textRotation => 180, :horizontal => :center})
			centered_style = p.workbook.styles.add_style(:alignment => { :horizontal => :center } )
			bg_style = p.workbook.styles.add_style(:bg_color => "FFC0C0C0",
                           :fg_color=>"#FF000000",
                           :border=>Axlsx::STYLE_THIN_BORDER)

  			p.workbook.add_worksheet(:name => "#{filename}") do |sheet|

  				dataSheet = sheet

				sheet.add_row ["Run on " + (Time.new).strftime("%-m/%-d at %I:%M") + " (Iteration Start Metrics based on day #{@iteration_start_day})" ]

  				@projects.each { |project| 

  					# print "Iterations:", @iterations[project].length, "\n"
  					next if @iterations[project].length == 0

	  				row0 = [project,"","Sprints"]
	  				@iterations[project].each { |e|
	  					row0.push("")
	  				}
	  				row0styles = row0.map { |cell| centered_style }

	    			sheet.add_row row0, :style => row0styles

	    			#ilabels = @iterations[project].map { |it| it["Name"] + " " + iteration_end_date(it) }
	    			ilabels = @iterations[project].map { |it| it["Name"] }
	    			istyles  = @iterations[project].map { cell_rotated_text_style }

	    			ilabels.unshift(nil)
	    			ilabels.unshift("Data Metric")
	    			
	    			istyles.unshift(nil)
	    			istyles.unshift(nil)
	    			
	    			sheet.add_row ilabels, :style => istyles

		      		colIndex = (("A".."Z").to_a[@iterations[project].length+1])
		      		cells1 = sheet.rows[sheet.rows.length-2].cells[0..1]

		      		cells = sheet.rows[sheet.rows.length-2].cells[2..@iterations[project].length+1]
		      		sheet.merge_cells(cells)
		      		sheet.merge_cells(cells1)
		      		sheet.rows[sheet.rows.length-2].cells[1].style = centered_style
		      		sheet.merge_cells( sheet.rows[sheet.rows.length-1].cells[0..1])
		      		sheet.rows[sheet.rows.length-1].cells[1].style = centered_style


		      		iCenteredstyles  = @iterations[project].map { centered_style }
		      		iCenteredstyles.unshift(nil)
		      		iCenteredstyles.unshift(nil)

	    			iStartDates = @iterations[project].map { |it| iteration_start_date(it) }
	    			iStartDates.unshift("Start")
	    			iStartDates.unshift(nil)

	    			sheet.add_row iStartDates, :style => iCenteredstyles

	    			iEndDates = @iterations[project].map { |it| iteration_end_date(it) }
	    			iEndDates.unshift("End")
	    			iEndDates.unshift(nil)
	    			sheet.add_row iEndDates, :style => iCenteredstyles

		      		# save the row
		      		project_rows[project] = sheet.rows.length - 2

		      		# write each metrics row
		      		@metrics_labels.each_with_index { |label,i|
		      			itmetrics = []
		      			#pp @iterations
		      			@iterations[project].each { |it|
		      				m = @metrics[project][it["ObjectID"].to_s][label]
	      					#itmetrics.push( m != 0 ? m : "" )
	      					itmetrics.push( m  )
		      			}
		      			row_style = ((i>=0&&i<=3) || (i>=8&&i<=12)) ? bg_style : nil
		      			itmetrics.unshift(label)
		      			itmetrics.unshift(nil)
		      			sheet.add_row itmetrics, :style => itmetrics.map { |m| row_style }
		      		}

		      		sheet.add_row []
		      	}
    		end

    		# add the graph worksheet
    		p.workbook.add_worksheet(:name => "Charts") do |sheet|

    			@projects.each_with_index { |project,i|

    				#pp "#{project} row:",project_rows[project]
    				prow = project_rows[project]
    				iters = @iterations[project]
    				start_row = (i*20) + ( i > 0 ? 1 : 0)
    				end_row = start_row + 20

    		# 		sheet.add_chart(Axlsx::Bar3DChart, :barDir => :col,
    		# 		#:start_at => [0,start_row], :end_at => [10, end_row], :title => "Iteration Metrics : " + project, :show_legend => true ) do |chart|
					 # :start_at => [0,start_row], :end_at => [10, end_row], :title => "Iteration Metrics : " + project ) do |chart|
    		# 			label_cells = dataSheet.rows[prow+1].cells[2..iters.length+1]
    		# 			# only graph the first 4
    		# 			@metrics_labels[0..3].each_with_index { |label,x| 
	    	# 				series_cells = dataSheet.rows[prow+2+x].cells[2..iters.length+2]
	    	# 				title_cells = dataSheet.rows[prow+2+x].cells[1]
	     #  					chart.add_series :data => series_cells,  :title => title_cells, :labels => label_cells #, :title => title_cells #:labels => label_cells,  :title => title_cells
	     #  					chart.catAxis.label_rotation = 45
	     #  					chart.valAxis.label_rotation = -45
	     #  					chart.valAxis.gridlines = false
    		# 				chart.catAxis.gridlines = false
    		# 				chart.catAxis.tick_lbl_pos = :none
    		# 				chart.valAxis.tick_lbl_pos = :none
      # 					}
    		# 		end
    			}

    		end

			# :labels => dataSheet["C2:J2"],
#    		sheet.add_chart(Axlsx::LineChart, 
#    				:start_at => [0,5], :end_at => [10, 20], :title => "Iteration Metrics", :show_legend => true ) do |chart|
#      					chart.add_series :data => dataSheet["C3:J3"], :labels => dataSheet["C2:J2"],  :title => dataSheet["B3"]
#      					chart.add_series :data => dataSheet["C4:J4"], :title => dataSheet["B4"]
#      					chart.add_series :data => dataSheet["C5:J5"], :title => dataSheet["B5"]
#    				end
    		#end

    		p.serialize("#{filename}.xlsx")
  		end
  		
	end

end

# validates the command line arguments

def validate_args args

	#pp args

	if args.size != 2
		false
	else
		config = JSON.parse(File.read(ARGV[0]))
		config["password"] = args[1]
		config
	end

end

config = validate_args(ARGV)

if  !config
	print "use: ruby xls-sprint-metrics.rb config.json <password>\n"
	exit
end

# if the cache directory does not exist create it.
if not File.directory? "cache"
	Dir::mkdir("cache")
end

url            = config["url"]
username       = config["username"]
password       = config["password"]
workspace_name = config["workspace_name"]
project_names   = config["project_name"]
number_of_iterations = config["number_of_iterations"]
iteration_start_day = config["iteration_start_day"] ? config["iteration_start_day"] : 1

print "Iteration Start Day:#{iteration_start_day}\n"

projects = project_names

print username,"\t",project_names,"\n"

project_metrics = {}
project_iterations = {}

# validate projects
project_names.each { |project_name| 
	lookbackdata = LookBackData.new( url, username, password, workspace_name, project_name, "log.txt", projects )
	if lookbackdata.find_object("Project",project_name) == nil
		abort( "'#{project_name}' not found!" )
	end
}


project_names.each { |project_name| 

	# initialize
	lookbackdata = LookBackData.new( url, username, password, workspace_name, project_name, "log.txt", projects )

	# finds the release(s) by name (if parent project there may be multiple releases for the name)
	# releases = lookbackdata.get_releases_by_name release_name
	iterations = lookbackdata.get_previous_iterations

	# truncate to just the last set of iterations
	if number_of_iterations != nil
		while ( iterations.length > number_of_iterations)
			iterations.shift
		end
	end

	metrics = lookbackdata.populate_metrics(project_name,iterations,metric_labels,iteration_start_day)

	project_metrics[project_name] = metrics
	project_iterations[project_name] = iterations

}

#xls = XLS.new(iterations,metrics,metric_labels)
xls = XLS.new(project_names,project_iterations,project_metrics,metric_labels,iteration_start_day)

xls.write_to_file workspace_name




