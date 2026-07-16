#import "HAPViewController.h"
#import "HAPPlayerViewController.h"

@interface HAPViewController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *hapInfoList;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UIButton *installButton;

@end

@implementation HAPViewController

- (instancetype)initWithHAPManager:(HAPManager *)manager {
    self = [super init];
    if (self) {
        self.hapManager = manager;
        self.hapInfoList = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"arkui容器";
    self.view.backgroundColor = [UIColor whiteColor];
    
    [self setupUI];
    [self loadHAPList];
}

- (void)setupUI {
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, 60)];
    headerView.backgroundColor = [UIColor colorWithRed:200/255.0 green:200/255.0 blue:200/255.0 alpha:1.0];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, screenWidth, 60)];
    titleLabel.text = @"arkui容器";
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [headerView addSubview:titleLabel];
    
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = headerView;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];
    
    self.installButton = [[UIButton alloc] initWithFrame:CGRectZero];
    [self.installButton setTitle:@"安装hap" forState:UIControlStateNormal];
    [self.installButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [self.installButton setBackgroundColor:[UIColor colorWithRed:200/255.0 green:200/255.0 blue:200/255.0 alpha:1.0]];
    self.installButton.titleLabel.font = [UIFont systemFontOfSize:18];
    [self.installButton addTarget:self action:@selector(installHAPFile) forControlEvents:UIControlEventTouchUpInside];
    self.installButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.installButton];
    
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.center = self.view.center;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.installButton.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        
        [self.installButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-34],
        [self.installButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.installButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.installButton.heightAnchor constraintEqualToConstant:50]
    ]];
}

- (void)loadHAPList {
    [self.loadingIndicator startAnimating];
    
    NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    
    [self.hapManager listAvailableHAPsInDirectory:documentsDir completion:^(NSArray<NSDictionary *> *hapInfoList, NSError *error) {
        [self.loadingIndicator stopAnimating];
        
        if (error) {
            NSLog(@"Failed to load HAP list: %@", error.localizedDescription);
            return;
        }
        
        [self.hapInfoList removeAllObjects];
        [self.hapInfoList addObjectsFromArray:hapInfoList];
        [self.tableView reloadData];
    }];
}

- (void)installHAPFile {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.item"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }
    
    NSURL *fileURL = urls[0];
    NSString *fileName = fileURL.lastPathComponent;
    
    if (![fileName hasSuffix:@".hap"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"请选择.hap格式的文件" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSError *copyError = nil;
    [fm copyItemAtURL:fileURL toURL:[NSURL fileURLWithPath:tempPath] error:&copyError];
    
    if (copyError) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:@"无法读取文件" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    [self.hapManager getHAPInfoFromPath:tempPath completion:^(NSString *appName, NSString *bundleName, NSError *error) {
        [fm removeItemAtPath:tempPath error:nil];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装确认" message:[NSString stringWithFormat:@"是否安装 %@?", appName] preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString *destPath = [documentsDir stringByAppendingPathComponent:fileName];
            
            NSFileManager *fm2 = [NSFileManager defaultManager];
            if ([fm2 fileExistsAtPath:destPath]) {
                [fm2 removeItemAtPath:destPath error:nil];
            }
            
            NSError *saveError = nil;
            [fm2 copyItemAtURL:fileURL toURL:[NSURL fileURLWithPath:destPath] error:&saveError];
            
            if (saveError) {
                UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:@"错误" message:@"安装失败" preferredStyle:UIAlertControllerStyleAlert];
                [errorAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:errorAlert animated:YES completion:nil];
                return;
            }
            
            [self loadHAPList];
        }]];
        
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // User cancelled
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.hapInfoList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"HAPCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"HAPCell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    
    NSDictionary *hapInfo = self.hapInfoList[indexPath.row];
    cell.textLabel.text = hapInfo[@"appName"];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
    cell.detailTextLabel.text = hapInfo[@"bundleName"];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    
    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    iconView.backgroundColor = [UIColor colorWithRed:200/255.0 green:200/255.0 blue:200/255.0 alpha:1.0];
    cell.imageView.image = iconView.image;
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 70;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *hapInfo = self.hapInfoList[indexPath.row];
    NSString *hapPath = hapInfo[@"path"];
    NSString *bundleName = hapInfo[@"bundleName"];
    
    [self.loadingIndicator startAnimating];
    
    [self.hapManager loadHAPAtPath:hapPath completion:^(BOOL success, NSString *errorMessage) {
        [self.loadingIndicator stopAnimating];
        
        if (success) {
            HAPPlayerViewController *playerVC = [[HAPPlayerViewController alloc] initWithHAPManager:self.hapManager bundleName:bundleName];
            [self.navigationController pushViewController:playerVC animated:YES];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加载失败" message:errorMessage preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    }];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSDictionary *hapInfo = self.hapInfoList[indexPath.row];
        NSString *hapPath = hapInfo[@"path"];
        
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:hapPath error:nil];
        
        [self.hapInfoList removeObjectAtIndex:indexPath.row];
        [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

@end