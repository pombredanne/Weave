'use strict';

/* Services */


/**
 * Query Object Service provides access to the main "singleton" query object.
 * 
 * Don't worry, it will be possible to manage more than one query object in the
 * future.
 */
angular.module("aws.services", []).service("queryobj", function() {
	this.title = "AlphaQueryObject";
	this.date = new Date();
	this.author = "UML IVPR AWS Team";
	this.scriptType = "r";
	this.dataTable = 1;
	this.conn = {
			scriptLocation : 'C:\\RScripts\\',
			connectionType: 'RMySQL',
			serverType : 'MySQL',
			sqlip : 'localhost',
			sqlport : '3306',
			sqldbname : 'sdoh2010q',
			sqluser : 'root',
			sqlpass : 'pass',
			schema : 'data',
			dsn : 'brfss'
	};
	this.slideFilter = {values: [10,25]}
	this.setQueryObject = function(jsonObj){
		if (!jsonObj){
			return undefined;
		}
		this.title = jsonObj.title;
		this.date = jsonObj.data;
		this.author = jsonObj.author;
		this.scriptType = jsonObj.scriptType;
		this.dataTable = jsonObj.dataTable;
		this.conn = jsonObj.conn;
		this.selectedVisualization = jsonObj.selectedVisualization;
		this.barchart = jsonObj.barchart;
		this.datatable = jsonObj.datatable;
		this.colorColumn = jsonObj.colorColumn;
		this.byvars = jsonObj.byvars;
		this.indicators = jsonObj.indicators;
		this.geography = jsonObj.geography;
		this.timeperiods = jsonObj.timeperiods;
		this.analytics = jsonObj.analytics;
		this.scriptOptions = jsonObj.scriptOptions;
		this.scriptSelected = jsonObj.scriptSelected;
		this.maptool = jsonObj.maptool;
	};
	return {
		//getSlideFilter: this.slideFilterI,
		//setSlideFilter: function(dat){ this.slideFilterI = dat; return this.slideFilterI;},
		//q: this,
		title: this.title,
		date: this.date,
		author: this.author,
		dataTable: function(){return this.dataTable;},
		conn: this.conn,
		slideFilter: this.slideFilter,
		getSelectedColumns: function(){
			//TODO hackity hack hack
			var col = ["geography", "indicators", "byvars", "timeperiods", "analytics"];
			var columns = [];
			for(var i = 0; i<col.length; i++){
				if(this[col[i]]){
					$.merge(columns, this[col[i]]);
				}
			}
			return columns;
		}
		
	}
	
		
})

angular.module("aws.services").service("scriptobj", ['queryobj', '$rootScope', '$q', function(queryobj, scope, $q){
	this.scriptMetadata = {"inputs":[],
	                       "outputs":[]
	};
	
	//this.availableScripts = [];
	this.updateMetadata = function(){
		this.scriptMetadata = this.getScriptMetadata();
	}
	
	this.getScriptsFromServer = function(){
		var deferred = $q.defer();
		var prom = deferred.promise;
		
		var callbk = function(result){
			scope.$safeApply(function(){
				console.log(result);
				deferred.resolve(result);
			});
		};
	
		aws.RClient.getListOfScripts(queryobj.conn.scriptLocation, callbk );
//		prom.then(function(result){
//			//this.availableScripts = result;
//			return result;
//		}); 
		return prom;
	};
	this.availableScripts = this.getScriptsFromServer();
	
	var that = this;
	this.getScriptMetadata = function(){
		var deferred2 = $q.defer();
		var promise = deferred2.promise;
		
		var callback = function(result){
			scope.$safeApply(function(){
				console.log(result);
				deferred2.resolve(result);
			});
		};
		
		aws.RClient.getScriptMetadata(queryobj.conn.scriptLocation, queryobj.scriptSelected, callback);
// 		promise.then(function(result){
// 			//return result;
// 		});
		//scope.$apply(); // testing if kicking off a digest cycle will update the UI properly. 
		return promise;
	};
	this.scriptMetadata = this.getScriptMetadata();  
	 
}]);

angular.module("aws.services").service("dataService", ['$q', '$rootScope', 'queryobj', 
   function($q, scope, queryobj){

	
	var fetchColumns = function(id){
		if(!id){
			alert("No DataTable Id Specified. Please update in the Data Dialog");
		}
		var deferred = $q.defer();
		var prom = deferred.promise;
		var deferred2 = $q.defer();
		
		var callbk = function(result){
			scope.$safeApply(function(){
				//console.log(result);
				deferred.resolve(result);
			});
		};
		var callbk2 = function(result){
			scope.$safeApply(function(){
				
				console.log(result);
				deferred2.resolve(result);
			});
		};
		
		aws.DataClient.getEntityChildIds(id, callbk);

		deferred.promise.then(function(res){
			aws.DataClient.getDataColumnEntities(res, callbk2);
		});
		
		prom = deferred2.promise.then(function(response){
			//console.log(response);
			return response;
		},function(response){
			console.log("error " + response);
		});
		
		return prom;
	};
	
	var fetchGeoms = function(){
		var deferred = $q.defer();
		var prom = deferred.promise;
		var deferred2 = $q.defer();
		var callbk = function(result){
			scope.$safeApply(function(){
				console.log(result);
				deferred.resolve(result);
			});
		};
		var callbk2 = function(result){
			scope.$safeApply(function(){
				
				console.log(result);
				deferred2.resolve(result);
			});
		};
		aws.DataClient.getEntityIdsByMetadata({"dataType":"geometry"}, callbk);
		deferred.promise.then(function(res){
			aws.DataClient.getDataColumnEntities(res, callbk2);
		});
		
		prom = deferred2.promise.then(function(response){
			//console.log(response);
			return response;
		},function(response){
			console.log("error " + response);
		});
		
		return prom;
	};
	
	
	var fullColumnObjs = fetchColumns(queryobj.dataTable);
	var fullGeomObjs = fetchGeoms();
	var filter = function(data, type){
		var toFilter = data;
		var filtered = [];
		for(var i = 0; i < data.length; i++){
			try{
				if(toFilter[i].publicMetadata.ui_type == type){
					filtered.push(toFilter[i]);
				}
			}catch(e){
				console.log(e);
			}
		}
		filtered.sort();
		return filtered;
	};
	
	return {
		giveMeColObjs: function(scopeobj){
			return fullColumnObjs.then(function(response){
					var type = scopeobj.panelType;
					return filter(response, type);
			});
		},
		refreshColumns: function(scopeobj){
			fullColumnObjs = fetchColumns(queryobj.dataTable);
		},
		giveMeGeomObjs: function(){
			return fullGeomObjs.then(function(response){
				return response;
			});
		}
	};
}]);