public with sharing class StrongpointVersionControlController {

    public class VersionControlException extends Exception {}

    private static final String NONE = '-- none --';
    private static final String GIT_RESOURCE_CLASS = 'Git';

    // regex adapted from https://stackoverflow.com/questions/12093748/how-do-i-check-for-valid-git-branch-names#12093994
    private static final String VALID_GIT_BRANCH_REGEX = '^(?!/|.*([/.]\\.|//|@\\{|\\\\\\\\))[^\\000-\\037\\0177 ~^:?*\\[]+(?<!\\.lock|[/.])$';

    // controller variables
    public String resourceType {get; set;}   // Name of the OAuth2 resource type (eg, GitHub)
    public String resourceName {get; set;}  // DeveloperName of the OAuth2_Credential__mdt record
    public String repositoryName {get; set;}
    public String branchName {get; set;}
    public String newBranchName {get; set;}
    public String commitMessage {get; set;}
    
    public List<SelectOption> resourceTypes {get; set;}
    public List<SelectOption> resourceNames {get; set;}
    public List<SelectOption> repositories {get; set;}
    public List<SelectOption> branches {get; set;}

    private VersionControlService versionControlService; 
    
    private Map<String, VersionControlService.RepositoryWrapper> repoMap;
    private Map<String, VersionControlService.BranchWrapper> branchMap;
    private VersionControlService.RepositoryWrapper repository;
    private VersionControlService.BranchWrapper branch;

    // Variables related to VCS Cr record creation
    public String saveErrorMessage {get; set;}
    public String saveSuccessfulMessage {get; set;}
    
    public Boolean isNewCommit {get; set;}
    public Boolean commitButtonDisabled {get; set;}
    //public Boolean crBranchNameExist {get; set;}
    
    // Ids via parameter
    public String crId {get;set;}
    
    public FLO_Change_Request__c changeRequest {get; set;}
    public Version_Control_System_Log__c vcsLog {get; set;}

    public CompletionStatus commitStatus {get; set;}
    public String commitStatusMessage {get; set;}

    // used for retrieving the zipped file of metadata
    private Id asyncResultId;
    public Boolean runPoll {get; set;}
    private Integer pollCounter;
    private FloZippex zippedFilesToCommit;

    // Customization list to be displayed in VF page
    //public List<List<InnerCusto>> custos {get;set;}
    
    @testVisible private static OAuth2CredentialSelector.IOAuth2CredentialSelector selector = new OAuth2CredentialSelector();

    // Class constructor
    public StrongpointVersionControlController () {        
        this.commitButtonDisabled = true;
        //this.crBranchNameExist = false;
        this.commitStatus = new CompletionStatus();
        this.commitStatusMessage = 'Not started.';
        initializePicklists();

        this.runPoll = false;

        // Get Cr id from parameters
        String crId = ApexPages.currentPage().getParameters().get('crId');
        if (crId != null) {
            //this.custos = getCustosList(crId);
            this.crId = crId;
            this.changeRequest = selectChangeRequestById(crId); 
            
            // get the Version Control System Logs associated with this CR
            List<Version_Control_System_Log__c> vcsLogs = selectVersionControlSystemLogsByCr(crId);
            if (vcsLogs.isEmpty()) {
                // build the branch info from user input
                this.isNewCommit = true;
            } else {
                // initialize the branch info form the most-recently-created log
                this.vcsLog = vcsLogs[0]; // most-recently-created log 
                this.isNewCommit = false;
                initializeExistingBranch(this.vcsLog);
            }
        }
    }


    private void initializePicklists() {
        this.resourceTypes = getOAuth2ResourceTypes();
        this.resourceNames = new List<SelectOption>{ new SelectOption(NONE, NONE) };
        this.repositories = new List<SelectOption>{ new SelectOption(NONE, NONE) };
        this.branches = new List<SelectOption>{ new SelectOption(NONE, NONE) };
    }


    // commitStatus parameters are updated from the vf page when the page intercepts commit events
    public void updateCommitStatus(){
        this.commitStatus.updateStatus(this.commitStatus.total, this.commitStatus.failures, this.commitStatus.completed);
    }


    private FLO_Change_Request__c selectChangeRequestById(Id crId) {
        return [SELECT id, Name, Parent_Change_Request__c, Change_Level_Required__c, Approval_Status__c,
                        Stage__c, Completion_Status__c, Approved_By__c, Approver_Notes__c, Rejected_By__c, 
                        Customizations__c, Affected_Processes__c, Impacted_Processes__c, Proposed_Customizations__c, 
                        Proposed_Process_es__c, Change_Overview__c, Additional_Approvers__c, Developers__c, 
                        Deployment_Assigned__c, SourceId__c, TargetId__c, Source_Enviroment__c, Target_Environment__c, 
                        Change_Type__c
                FROM FLO_Change_Request__c 
                WHERE id =: crId 
                LIMIT 1];
    }


    // NOTE: results are returned with most recently-created records first
    private List<Version_Control_System_Log__c> selectVersionControlSystemLogsByCr(Id crId) {
        return [SELECT Id, Resource_Type__c, Resource_Name__c, Repository_Name__c, Branch_Name__c,
                        Start_Date__c, Completed_Date__c, Async_Job_Id__c, Status__c,
                        Exception_Type__c, Job_Scope__c, Message__c, Phase__c, Stack_Trace__c
                FROM Version_Control_System_Log__c
                WHERE Change_Request__c = :crId
                ORDER BY CreatedDate DESC];
    }


    private void initializeExistingBranch(Version_Control_System_Log__c vcsLog) {
system.debug('*** initializeBranch');
        this.resourceTypes = getOAuth2ResourceTypes();
        this.resourceType = vcsLog.Resource_Type__c;
system.debug('*** after init resourceType');
        this.resourceNames = getOAuth2Credentials();
        this.resourceName = vcsLog.Resource_Name__c;
system.debug('*** after init resourceName');
        setVersionControlService();
system.debug('*** after init setVCS');
        this.repositories = updateRepositories();
system.debug('*** after init updateRepositories');
        this.repositoryName = vcsLog.Repository_Name__c;
system.debug('*** after init repositoryName');
        setRepository();
system.debug('*** after setRepository');
        //this.branches = updateBranches();
//system.debug('*** after updateBranches');
        this.branchName = vcsLog.Branch_Name__c;
system.debug('*** after init branchName');
        setBranch();
system.debug('*** after setBranch');
        this.commitButtonDisabled = false;
system.debug('*** after commitButton enable');
    }

    
    // delegates to the OAuth2CredentialService to get the resource types
    public List<SelectOption> getOAuth2ResourceTypes() {
system.debug('*** getOAuth2ResourceTypes');     
        List<SelectOption> oauth2ResourceTypes = new List<SelectOption>();
        oauth2ResourceTypes.add(new SelectOption(NONE, NONE));
        try {
            for (OAuth2_Resource_Type__mdt resource: selector.selectResourcesByClass(GIT_RESOURCE_CLASS)) {
                oauth2ResourceTypes.add(new SelectOption(resource.DeveloperName, resource.Label));
            }
        } catch(OAuth2CredentialSelector.OAuth2CredentialSelectorException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }

        return oauth2ResourceTypes;
    }    


    public Pagereference setResourceType() {
        this.resourceName = null;
        this.resourceNames = getOAuth2Credentials();
        setResourceName();
        return null;
    }


    public List<SelectOption> getOAuth2Credentials() {
system.debug('*** getOAuth2Credentials');       
        List<SelectOption> oauth2Credentials = new List<SelectOption>();
        oauth2Credentials.add(new SelectOption(NONE, NONE));

        if (!String.isBlank(this.resourceType) && this.resourceType != NONE) {
            try {   
                for (OAuth2_Credential__mdt credential: selector.selectCredentialsByType(this.resourceType)) {
                    oauth2Credentials.add(new SelectOption(credential.DeveloperName, credential.Label));
                }
            } catch(OAuth2CredentialSelector.OAuth2CredentialSelectorException e) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
            }
        }
        
        return oauth2Credentials;
    }
 

    public Pagereference setResourceName() {
        setVersionControlService();
        this.isNewCommit = true;
        resetRepositories();
        return null;
    }


    // set the versionControlService via Dependency Injection
    private void setVersionControlService() {
system.debug('*** setVersionControlService');
        this.versionControlService = null;
        if (!String.isEmpty(this.resourceName) && this.resourceName != NONE) {
            try {
                OAuth2_Credential__mdt credential = selector.selectOAuth2CredentialByName(this.resourceName);
                System.debug('**** credential.Data_Service_Class__c:'+credential.Data_Service_Class__c);
                // TODO: make Namespace Prefix dynamic
                // NOTE: Type.forName has two constructors forName(class) and forName(namespace,class)
                Type t = Type.forName(credential.Data_Service_Class__c); // uncomment for alliance 
                //Type t = Type.forName('FLODocs',credential.Data_Service_Class__c); // uncomment for golden || package
                this.versionControlService = (VersionControlService) t.newInstance();
                System.debug('vcs: ' + this.versionControlService);
                this.versionControlService.setCredential(credential);
            } catch(OAuth2CredentialSelector.OAuth2CredentialSelectorException e) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
            } catch(Exception e) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
            }
        }
    }


    private void resetRepositories() {
system.debug('*** resetRepositories');
        this.repositoryName = null;
        this.repository = null;
        this.repositories = updateRepositories();

        resetBranches();
    }
        

    public List<SelectOption> updateRepositories() {
system.debug('*** updateRepositories');
        List<SelectOption> repositories = new List<SelectOption>();
        repositories.add(new SelectOption(NONE, NONE));

        if (this.versionControlService != null) {
            try {               
                this.repoMap = this.versionControlService.getRepositories();
                for (String repoName: this.repoMap.keySet()) {
                    repositories.add(new SelectOption(repoName, repoName));
                }
            } catch(OAuth2DataService.OAuth2DataServiceException e) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
            }
        }

        return repositories;
    }

    public Pagereference setRepository() {
system.debug('*** setRepository');
        this.repository = this.repoMap.get(this.repositoryName);
        resetBranches();
        return null;
    }


    private void resetBranches() {
system.debug('*** resetBranches');
        this.branchName = null;
        this.newBranchName = null;
        this.branch = null;
        this.branches = updateBranches();
    }


    public List<SelectOption> updateBranches() {
system.debug('*** updateBranches');
        List<SelectOption> branches = new List<SelectOption>();
        branches.add(new SelectOption(NONE, NONE));

        if (this.versionControlService != null && this.repository != null) {
            try {
                this.branchMap = this.versionControlService.getBranches(this.repository);
                for (String branchName: this.branchMap.keySet()) {
                    branches.add(new SelectOption(branchName, branchName));
                }
            } catch(OAuth2DataService.OAuth2DataServiceException e) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
            }
        }

        return branches;
    }


    public Pagereference setBranch() {
system.debug('*** setBranch');
        if (this.branchName == NONE) return null;

        if (!this.branchMap.containsKey(this.branchName)) throw new VersionControlException('BranchMap does not contain ' + this.branchName);

        this.branch = this.branchMap.get(this.branchName);
        if(this.branchName == NONE) {
            this.commitButtonDisabled = true;
        } else {
            this.commitButtonDisabled = false;
            if (this.isNewCommit) {
                // provide default value for new branch
                //this.newBranchName = this.changeRequest.Key__c;  // autonumber Key__c field couldn't be added to pkg
                // default name is the CR name where any non-alphanumeric is replaced with a dash
                this.newBranchName = this.changeRequest.Name.replaceAll('[^\\w]','-');
            }
        }
        return null;
    }
    
    
    
    public void setSaveSuccessfulMessage(String message) {
        this.saveSuccessfulMessage = message;
    }

    public Boolean validInputData() {
        Boolean result = true;
        if((String.isEmpty(this.newBranchName) && this.branchName == NONE) || this.repositoryName == NONE || this.resourceName == NONE || this.resourceType == NONE) {
            result = false;
        }
        return result;
    }


    public Pagereference validateNewBranchName() {
        
        //SF-1596 on error, force reset of new branch name field and commit button status
        if (!String.isEmpty(this.newBranchName)) {
            if (!Pattern.matches(VALID_GIT_BRANCH_REGEX, this.newBranchName)) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, '"' + this.newBranchName + '" is not a valid Git branch name.'));
                this.newBranchName = '';
                this.commitButtonDisabled = false;
                return null;
            }
        
            if (this.branchMap.containsKey(this.newBranchName)) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, 'Reposity already contains a branch with name "' + this.newBranchName + '".'));
                this.newBranchName = '';
                this.commitButtonDisabled = false;
                return null;
            }
        }
        
        // if the branch name is valid, fire a 'Request Zip' event
        CommitEvent event = new CommitEvent();
        event.changeRequestId = this.crId;
        event.status = 'Request Zip';
        event.fire();

        return null;

    }


    public Pagereference commitCR(){

        // if the user enters a newBranchName, then try to create the new branch from the existing branch
        if (!String.isEmpty(this.newBranchName)) {
            try {
                createNewBranch();
            } catch(VersionControlException e) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
                return null;
            }
        }

        // populate the commit info and queue the job that's going to do the commit to the remote repository
        VersionControlService.CommitWrapper commitWrapper = new VersionControlService.CommitWrapper();
        commitWrapper.vcsLogId = this.vcsLog.Id;
        commitWrapper.changeRequestId = this.changeRequest.Id;
        commitWrapper.message = this.commitMessage;
        commitWrapper.username = UserInfo.getName();
        commitWrapper.zippedFilesToCommit = this.zippedFilesToCommit;
        commitWrapper.branch = this.branch;

        System.enqueueJob(new CommitQueueable(this.versionControlService, commitWrapper));
    
        return null;
    }


    private void createNewBranch() {
        // the new branch (newBranchName) will branch off the current branch (branchName)
        this.branch = this.branchMap.get(this.branchName);

        try {   
            this.versionControlService.createBranch(this.branch, this.newBranchName);
        } catch(OAuth2DataService.OAuth2DataServiceException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }

        // refresh branchMap to include the newly-created branch and set the current branch to the newly-created branch
        this.branchMap = this.versionControlService.getBranches(repository);
        this.branch = this.branchMap.get(this.newBranchName);
    }


    private List<StrongpointDeploymentController.InnerCusto> getCustomizationsToCommit() {
        
        StrongpointDeploymentController ctl = new StrongpointDeploymentController();
        // this method restricts each sublist to 1000 elements
        List<List<StrongpointDeploymentController.InnerCusto>> customizationLists = ctl.getCustosList(this.crId);

        List<StrongpointDeploymentController.InnerCusto> customizations = new List<StrongpointDeploymentController.InnerCusto>();
        for (List<StrongpointDeploymentController.InnerCusto> ics: customizationLists) {
            customizations.addAll(ics);
        }
        
        if (customizations.isEmpty()) throw new VersionControlException('Could not find any Customizations to commit.');
        
        return customizations;
    }


    public void requestZipFile() {
        FloMetadataService.AsyncResult asyncResult = null;

        try {
            List<StrongpointDeploymentController.InnerCusto> customizations = getCustomizationsToCommit();
        
            /*********** all this code is copied over from StrongpointDeploymentBatchable **********/
            FloMetadataService.MetadataPort service = FloUtils.createService(UserInfo.getSessionId());
        
            FloMetadataService.RetrieveRequest retrieveRequest = new FloMetadataService.RetrieveRequest();
            retrieveRequest.apiVersion = 47.0; // to match StrongpointDeploymentBatchable
            retrieveRequest.packageNames = null;
            retrieveRequest.singlePackage = true;
            retrieveRequest.specificFiles = null;
            retrieveRequest.unpackaged = new FloMetadataService.Package_x();
            retrieveRequest.unpackaged.types = new List<FloMetadataService.PackageTypeMembers>();
        
            Map<String, List<String>> typeToCustos = new Map<String, List<String>>();
            Set<String> addedFolders = new Set<String>();
            //GF 20200810 SF-1291 Deploy Feature - When the Encoded Api Name for the customization that you are going to deploy is different to the scriptId, the deployment fails
            // Replace ic.custoName by ic.custoEncodedName
            for (StrongpointDeploymentController.InnerCusto ic: customizations) {
                if (typeToCustos.get(ic.custoType) != null) {
                    if (ic.custoType == 'CustomTab' || ic.custoType == 'Workflow') {
                        if (ic.custoEncodedName.contains('CustomTab')) {
                        typeToCustos.get(ic.custoType).add(ic.custoEncodedName.replace('.CustomTab', ''));
                        }
                        if (ic.custoEncodedName.contains('Workflow')) {
                        typeToCustos.get(ic.custoType).add(ic.custoEncodedName.replace('.Workflow', ''));
                        }
                    } else {
                        typeToCustos.get(ic.custoType).add(ic.custoEncodedName);
                        if (ic.custoType == 'Document' || ic.custoType == 'Report' || ic.custoType == 'Dashboard' ||  ic.custoType == 'EmailTemplate') {
                            String folderName = ic.custoEncodedName.split('/')[0];
                            if (!addedFolders.contains(folderName + '-' + ic.custoType) && (folderName != 'unfiled$public')) {
                                typeToCustos.get(ic.custoType).add(folderName);
                                addedFolders.add(folderName + '-' + ic.custoType);
                            }
                        }
                    }
                } else {
                    if (ic.custoType == 'CustomTab' || ic.custoType == 'Workflow') {
                        if (ic.custoEncodedName.contains('CustomTab')) {
                            typeToCustos.put(ic.custoType, new List<String>{ic.custoEncodedName.replace('.CustomTab', '')});
                        }
                        if (ic.custoEncodedName.contains('Workflow')) {
                            typeToCustos.put(ic.custoType, new List<String>{ic.custoEncodedName.replace('.Workflow', '')});
                        }
                    } else {
                        typeToCustos.put(ic.custoType, new List<String>{ic.custoEncodedName});
                        //typeToCustos.put(ic.custoType, new List<String>{ic.custoEncodedName.replaceAll('FLODocs__','')}); //GF descomentar
                        if (ic.custoType == 'Document'|| ic.custoType == 'Report' || ic.custoType == 'Dashboard'  ||  ic.custoType == 'EmailTemplate') {
                            String folderName = ic.custoEncodedName.split('/')[0];
                            if (!addedFolders.contains(folderName + '-' + ic.custoType) && (folderName != 'unfiled$public')) {
                                typeToCustos.get(ic.custoType).add(folderName);
                                addedFolders.add(folderName + '-' + ic.custoType);
                            }
                        }
                    }
                }
            }

            retrieveRequest.unpackaged.types = new List<FloMetadataService.PackageTypeMembers>();
            for (String sfdcType: typeToCustos.keySet()) {
                FloMetadataService.PackageTypeMembers packageType = new FloMetadataService.PackageTypeMembers();
                List<String> custosAsList = new List<String>();
                custosAsList.addall(typeToCustos.get(sfdcType));
                system.debug('custosAsList in createPackageXML() :' + custosAsList);
                packageType.members = custosAsList; 
                packageType.name = sfdcType;
                retrieveRequest.unpackaged.types.add(packageType);
            }

            System.debug('******---->>>> STEP 2 getZipFileFromMetadata');
            asyncResult = service.retrieve(retrieveRequest);
            System.debug('******---->>>> STEP 3 getZipFileFromMetadata');
            if (asyncResult == null) throw new VersionControlException('On retrieve(), asyncResult is null.'); 
            this.asyncResultId = asyncResult.Id;
        } catch (VersionControlException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }

        // turn on the ApexPage poller
        this.runPoll = true;
    }
    

    public void checkRetrieveStatus() {     
        FloMetadataService.RetrieveResult result = null;

        FloMetadataService.MetadataPort service = FloUtils.createService(UserInfo.getSessionId());

        try {
            if (this.asyncResultId == null) throw new VersionControlException('Tried to retrieve Zip file status with no asyncResultId.');

            // call checkRetrieveStatus() with "false" in order to see if the zip file is complete without actually retrieving it
            result = service.checkRetrieveStatus(this.asyncResultId, false);
        
            if (result == null) throw new VersionControlException('Zip file AsyncResult was null.');
            if (result.done) {
                this.runPoll = false;
                this.commitStatusMessage = 'Preparing zip file . . .';
                retrieveZipFile();
                createNewVcsLog();
                attachZipFileToVcsLog(this.vcsLog.Id, this.zippedFilesToCommit);

                // if the branch name is valid, fire a 'Request Zip' event
                CommitEvent event = new CommitEvent();
                event.changeRequestId = this.crId;
                event.status = 'Ready to Commit';
                event.fire();
            }
        } catch (VersionControlException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
    }

    
    private void retrieveZipFile() {
        FloMetadataService.RetrieveResult result = null;
        
        FloMetadataService.MetadataPort service = FloUtils.createService(UserInfo.getSessionId());

        try {
            if (this.asyncResultId == null) throw new VersionControlException('Tried to retrieve Zip file with no asyncResultId.');

            // call checkRetrieveStatus() with "true" in order to retrieve the zip file
            result = service.checkRetrieveStatus(this.asyncResultId, true);

            if (result == null) throw new VersionControlException('Zip file AsyncResult was null.');
            if (String.isEmpty(result.zipFile)) throw new VersionControlException('Zip file is empty.');
            this.zippedFilesToCommit = new FloZippex(EncodingUtil.base64Decode(result.zipFile));

            // the api that packages the customizations automatically creates a package.xml file; we don't need this
            this.zippedFilesToCommit.removeFile('package.xml');
        } catch (VersionControlException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
    }


    private void createNewVcsLog() {
        Version_Control_System_Log__c vcsLog = new Version_Control_System_Log__c();
        vcsLog.Branch_Name__c = String.isEmpty(this.newBranchName) ? this.branchName : this.newBranchName;
        vcsLog.Change_Request__c = this.changeRequest.Id;
        vcsLog.Customizations__c = this.changeRequest.Customizations__c;
        vcsLog.Repository_Name__c = this.repositoryName;
        vcsLog.Resource_Name__c = this.resourceName;
        vcsLog.Resource_Type__c = this.resourceType;
        vcsLog.Commit_Message__c = this.commitMessage;
        vcsLog.Status__c = 'Not Started';
        insert vcsLog;

        this.vcsLog = vcsLog;
    }


    private void attachZipFileToVcsLog(Id vcsLogId, FloZippex zippedFilesToCommit) {
        
        try {
            Attachment att = new Attachment();
            att.ParentId = vcsLogId;
            // we really should have tested for this and thrown an error earlier
            if (zippedFilesToCommit == null) throw new VersionControlException('No zip file to attach to VCS Log.');
            att.Body = zippedFilesToCommit.getZipArchive();
            att.Name = 'Files Committed.zip';
            att.ContentType = 'application/zip';
            insert att;
        } catch (VersionControlException e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
    }


    //Get list of customizations
    /*
    public List<List<InnerCusto>> getCustosList(String crId) {
        List<String> custoIds = new List<String>();
        
        RecordType recordType = [SELECT id FROM RecordType WHERE DeveloperName = 'Change_Request_to_Customization' LIMIT 1];
        for(FLO_Junction__c junction : [SELECT Id, FLO_Customization_Target__c, FLO_Customization_Target__r.Name, FLO_Customization_Target__r.ScriptId__c
                                                FROM FLO_Junction__c 
                                                WHERE FLO_Change_Request_Source__c =: crId
                                                    AND RecordTypeId =: recordType.id]) {
            custoIds.add(junction.FLO_Customization_Target__c);
        }

        List<InnerCusto> returnList = new List<InnerCusto>();
        List<List<InnerCusto>> returnLists = new List<List<InnerCusto>>();
        for (FLO_Customization__c custo: [SELECT Id, ScriptId__c, Name, Salesforce_Types__c FROM FLO_Customization__c WHERE id =: custoIds]) {
            InnerCusto cust = new InnerCusto();
            cust.isSelected = true;
            cust.exist = true;
            cust.custoName = custo.ScriptId__c;
            cust.custoId = custo.id;
            cust.custoType = custo.Salesforce_Types__c == 'GlobalPicklist' ? 'GlobalValueSet' : custo.Salesforce_Types__c;
            cust.deployMessage = '';

            if(returnList.size() < 1000){
                returnList.add(cust);
            }else{
                returnLists.add(returnList);
                returnList = new List<InnerCusto>();
                returnList.add(cust);
            }            
        }
        if (returnLists.isEmpty()) {
            returnLists.add(returnList);
        }
        
        return returnLists;
    }   
    */
    
    // Inner class to display Selected customization information
    /*
    public class InnerCusto{
        public boolean isSelected {get;set;}
        public boolean exist {get;set;}
        public String custoName {get;set;}
        public String custoId {get;set;}
        public String custoType {get;set;}
        public String deployMessage {get;set;}
        public String rollbackType {get;set;}
    }
    */  
}